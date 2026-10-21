# SPEC — Model Router vNext (planejamento futuro, SEM código/rollout)

> **HEADER EXPLÍCITO: SEM CÓDIGO / SEM ROLLOUT NESTA FASE.**
> Este documento é planejamento puro para a issue #99 (BACKLOG/PLANEJAMENTO FUTURO, V2-only, V1 `LEGACY_FROZEN`).
> Nada aqui ativa flag, altera modelo, edita registry/template/agente, ou autoriza implementação.
> Implementação futura exige SPEC+PLAN aprovados + gate humano + prova de override no runtime exato.
> `docs/specs/INDEX.md` NÃO foi alterado (decisão do Planner pendente — ver §12).

**Issue:** #99 — Model Router (adaptativo)
**Status:** `draft-backlog` (não priorizado; depende de prova técnica — ver §6)
**Change class:** `FEATURE_REEVALUATION` (futura; sem `AUTHORITY_CHANGE` nesta fase)
**Escopo de runtime:** V2-only. V1 é `LEGACY_FROZEN` — nenhuma mudança V1 é proposta ou permitida.
**Companion PLAN:** `MODEL-ROUTER-vNext-PLAN.md`
**Base factual:** INV-99 (inventário da issue #99; despacho real, pools estáticos, ausência de campo modelo).

**Documentos relacionados:**

- `UNIVERSAL-AUTONOMOUS-ORCHESTRATION-v0.1.0-SPEC.md` — SPEC ativa v0.1.0 (padrão de estrutura seguido aqui).
- `source/registry/jev-advisory-policy.json` — policy advisory-only; `select-model` recusado.
- `source/registry/capability-routing.json` — roteamento de AGENTE (não de modelo); shadow.
- `source/registry/execution-budget-policy.json` — budgets por papel (sem custo monetário).
- `templates/opencode.v2.json.tmpl` — modelo estático por agente (`{{MODEL_CHEAP}}` / `{{MODEL_STRONG}}`).
- `models.jsonc` (local, git-ignored) — `planner` / `cheap` / `strong` (3 slots, sem granularidade por tarefa).

---

## 1. Problema

O modelo por worker é estático por agente e resolvido fora do despacho:

1. `templates/opencode.v2.json.tmpl:39-169` — cada agente declara `"model": "{{MODEL_CHEAP}}"` ou `"{{MODEL_STRONG}}"`; `build` não fixa modelo (herda sessão, `source/adapters/opencode-v2.md:41-44`).
2. O despacho real é o Planner-LLM via tool nativa `subagent` (`source/adapters/opencode-v2.md:121-134`); scripts PS nunca spawnam workers (apenas decidem/validam).
3. O contrato `New-OrchestrationNativeDispatchIntent` (`scripts/v3/lib/OrchestrationNativeDispatch.ps1:791-905`) NÃO possui campo modelo — params são `TaskId, TaskExpectedRevision, Agent, PromptHash, Scope, AcceptanceCriteria, IdempotencyKey, Owner, OwnershipGeneration, BaseRevision, ExternalIdempotent, ExternalIdempotencyProof` (ver §6, prova).
4. O "override por delegação" citado em `source/adapters/opencode-v2.md:51,56-64` é prosa de policy (ordem de escala + cotas Astra), sem plumbing: nenhum contrato, pipeline ou executor carrega campo modelo.
5. `OrchestrationDecisionProvider.ps1:423-436` + `jev-advisory-policy.json:44-56,89-100` recusam `select-model` (reason `model-selection-reserved`); qualquer pergunta/alternativa com keyword de modelo é recusada antes de qualquer consulta Jev.

Consequência: hoje NÃO existe caminho implementado para escolher modelo por tarefa; existe apenas (a) troca estática via `models.jsonc` (operador, fora do despacho) e (b) override manual prosaico do Planner no spawn (não tipado, não validado, não auditado).

## 2. Não-objetivos (nesta SPEC, nesta fase)

- Implementar qualquer router, campo, flag, registry ou telemetria nova.
- Alterar `models.jsonc`, templates, `source/agents/*.md`, registries ou adapter.
- Ativar qualquer flag (`capability_router.*`, `skill_routing`, `mcp_routing`, `adaptive_ranking` continuam OFF/shadow por doutrina).
- Comentar na issue #99 no GitHub, fazer commit, ou declarar prontidão de release.
- Substituir o Planner como Control Plane, o Kernel como authority boundary, ou o DONE gate.

## 3. Limites de autoridade (sem duplicação)

| Componente | Pode | NÃO pode (duplicação proibida) |
|---|---|---|
| Planner (`build`) | Decisão final de despacho; aplicar override explícito do usuário; registrar TDR | Delegar decisão final a qualquer router/advisor; ampliar grants/scope próprios |
| CapabilityRouter (agente) | Propor AGENTE dentro do envelope Stage 1/2 (`source/adapters/opencode-v2.md:236-334`); shadow/advisory por default | Selecionar modelo; conceder grant; autorizar produção; sobrescrever Verifier/Reviewer/Security |
| DecisionProvider + Jev | Responder perguntas tipadas (`routing, specialist, continue, parallel, evidence, risk, hypothesis, alternative` — `jev-advisory-policy.json:59-68`); advisory-only | `select-model` e 7 verbos correlatos (`jev-advisory-policy.json:44-56`); qualquer keyword de modelo (`:89-100` → `model-selection-reserved`, `OrchestrationDecisionProvider.ps1:423-436`) |
| **Model Router (proposto, FUTURO)** | Propor MODELO dentro de envelope de custo/policy por (agente, classe); sempre com fallback determinístico = baseline estático atual | Escolher agente; conceder grant; autorizar produção/destruição/credencial; sobrescrever Verifier/Reviewer/Security/DONE; consultar sem budget; impor custo pago sem autorização |
| Task Kernel | Authority boundary: grants, ownership, leases, scope, Verifier, Reviewers, DONE (`...-v0.1.0-SPEC.md` §6 INV-005) | Delegar authority a router/advisor; aceitar claim de worker como prova |
| Runtime V2 (`subagent`) | Único executor real de spawn (Planner-LLM → child session) | Ser assumido como suporte a parâmetro modelo sem prova no runtime exato (ver §6) |

Regra de precedência futura (quando e SE implementado): invariantes de policy (deny, allowlist/matriz §5, autorização paga/ambiente, cotas, grants/scope) > override explícito do usuário > proposta do Model Router > baseline estático. Override elimina a CONSULTA ao router, nunca a VALIDAÇÃO: override para modelo proibido, com cota esgotada, fora de grants/scope, ou pago sem autorização é recusado (`DENY_POLICY`) com fallback ao baseline. Jev nunca entra nesta cadeia como decisor de modelo.

## 4. Contratos propostos (tipados, SOMENTE especificação — sem implementação)

### 4.1 `ModelRoutingRequest`

| Campo | Tipo | Obrigatório | Notas |
|---|---|---|---|
| `task_id` | string | sim | id canônico da task (`criterion:<idx>` refs preservados no DispatchIntent) |
| `role` | enum (19 agentes) | sim | `coder, explorer, researcher, tester, reviewer, debugger, security-reviewer, architect, docs-manager, frontend-engineer, backend-engineer, database-engineer, ai-agent-engineer, automation-engineer, infra-engineer, requirements-analyst, engineering-advisor, product-designer, skeptic` |
| `task_class` | enum (12) | sim | `capability-routing.json:7-20` (`implementation, migration, analysis, research, debugging, validation, review, documentation, planning, design, testing, trivial`) |
| `risk` | enum | sim | `LOW, MEDIUM, HIGH, CRITICAL` (`capability-routing.json:93-106`); `HIGH` nunca consulta Jev (`OrchestrationDecisionProvider.ps1:446-450` — padrão herdado) |
| `context_signals` | objeto | sim | tamanho contexto, evidência reuse hit/miss, retry count, incerteza classificada — SOMENTE enums/ints/hashes (sem texto livre/segredo, padrão telemetria `opencode-v2.md:274-276`) |
| `cost_limits` | objeto | sim | `max_escalations_subtask ≤ 1`, `max_above_baseline_per_objective ≤ 2`, `max_paid_calls = 0` default — conta SOMENTE chamadas pagas ADICIONAIS do router ((b) consultas Jev/router pagas + (c) escalonamentos pagos); (a) custo do baseline pago-atual fica FORA do router (ver §8 item 5); override pago exige autorização explícita por ambiente |
| `candidates` | string[] | sim | subconjunto allowlisted da matriz §5; fora da matriz → `candidate_out_of_envelope` |
| `capabilities_required` | string[] | não | ex. `long-context, vision, tool-use-forte`; nunca contém segredo |
| `uncertainty` | enum | não | `low, medium, high` — `high` + risco ≥ MEDIUM → Planner decide sem router (fallback determinístico) |
| `user_model_override` | string \| null | não | override explícito do usuário; quando presente, router NÃO é consultado (preservação §4.3) |

### 4.2 `ModelRoutingResult`

| Campo | Tipo | Notas |
|---|---|---|
| `selected` | string \| null | modelo allowlisted ou `null` (= baseline estático do agente) |
| `reason` | enum | `BASELINE_SUFFICIENT, ESCALATE_COMPLEXITY, CHEAPEN_COST, OVERRIDE_USER, FALLBACK_DETERMINISTIC, DENY_POLICY, PROOF_ABSENT` |
| `confidence` | number 0–1 | `< 0.5` → fallback determinístico (espelha `min_confidence: 0.5`, `jev-advisory-policy.json:70`) |
| `fallback` | string | sempre preenchido = baseline estático (`{{MODEL_CHEAP}}` / `{{MODEL_STRONG}}` por agente) |
| `policy_refs` | string[] | refs exatas: policy de custo, cotas (`opencode-v2.md:56-64`), matriz §5 linha |
| `evidence_refs` | string[] | benchmark run ids (§7 PLAN) ou `NO_EVIDENCE_YET` (estado atual) |
| `escalation_consumed` | bool | se consumiu 1 das cotas do objetivo pai |

### 4.3 Preservação de overrides explícitos

1. `user_model_override` presente → sem consulta ao router; despacho usa o override APÓS validação e registra `OVERRIDE_USER` (ou `DENY_POLICY` + fallback ao baseline se inválido).
2. Override nunca amplia grants, scope, produção, destruição ou credenciais (mesma regra do Dispatch Contract, `opencode-v2.md:371`).
3. Override pago (`Astra`/qualquer modelo tarifado) exige autorização explícita para aquele ambiente; ausência = `false` (espelha `PRODUCTION_AUTHORIZED`, `opencode-v2.md:371`).
4. Validação invariante ANTERIOR ao override (deny, allowlist/matriz §5, cotas §4.1, grants/scope): override para modelo proibido, com cota esgotada ou fora de grants/scope é recusado com `DENY_POLICY` e fallback ao baseline — override nunca bypassa modelos proibidos, cotas, grants/escopo, nem autorização paga/ambiente.

## 5. Matriz 19 agentes × classes × candidatos (proposta, NÃO normativa)

Baseline estático atual (normativo hoje): 14 cheap + 4 strong + `build` inherited — `templates/opencode.v2.json.tmpl:37-169`, `models.jsonc:3-8`, `opencode-v2.md:39-55`.

| Agente (baseline) | Classes típicas | Candidatos futuros (dentro do pool) | Proibido |
|---|---|---|---|
| `build` Planner (inherited) | todas (control plane) | N/A — Planner nunca é roteado; modelo = sessão | Qualquer seleção pelo router; fixar modelo no perfil |
| `coder` (cheap) | implementation, trivial | cheap default; strong SOMENTE se 2ª falha + Debugger exigir (via Planner, cotas §4.1) | strong por default; paid sem autorização |
| `explorer` (cheap) | analysis, research | cheap apenas | strong/paid (leitura não justifica escala — `opencode-v2.md:56-64` "falta informação ≠ falta inteligência") |
| `researcher` (cheap) | research | cheap apenas | strong/paid pelo mesmo motivo |
| `tester` (cheap) | testing, validation, E2E | cheap apenas | strong (assurance a jusante; escala é de escopo, não de modelo) |
| `reviewer` (strong) | review | strong baseline; cheap NUNCA (independência + qualidade) | cheapen de reviewer |
| `debugger` (strong) | debugging | strong baseline | cheap para bug difícil (hipótese falsificável exige capacidade) |
| `security-reviewer` (strong) | review (security) | strong SEMPRE | qualquer cheapen; qualquer bypass (`security_sensitive` vence tudo) |
| `architect` (strong) | planning, design, migration | strong baseline | cheap para decisão irreversível/cross-cutting |
| `docs-manager` (cheap) | documentation | cheap apenas | strong (docs internas não justificam) |
| `frontend-engineer` (cheap) | implementation (UI) | cheap default; strong SOMENTE risco arquitetural UI material | strong por menção de tecnologia (regra `opencode-v2.md:145-151`) |
| `backend-engineer` (cheap) | implementation (API) | idem | idem |
| `database-engineer` (cheap) | migration, implementation (schema) | cheap default; strong SOMENTE migração irreversível/HIGH | cheap para migração HIGH/CRITICAL sem Planner+Debugger |
| `ai-agent-engineer` (cheap) | implementation (ai) | cheap default; HOLD de envelope (fora Stage 1/2 — `opencode-v2.md:252-254,323-327`) | roteamento ativo antes de envelope próprio |
| `automation-engineer` (cheap) | implementation (automação) | idem HOLD | idem |
| `infra-engineer` (cheap) | implementation (Stage 2) / planning | cheap default; strong NUNCA para mutação (deterministic-first — `opencode-v2.md:314-319`) | qualquer escala para `infra_mutation` |
| `requirements-analyst` (cheap) | planning | cheap → Sol SOMENTE requisitos estruturalmente complexos (`opencode-v2.md:200-206`) | Sol/high; paid |
| `engineering-advisor` (cheap) | planning/advisory | cheap → Sol → Sol/high (`opencode-v2.md:200-206`) | paid; reconsulta sem evidência nova |
| `product-designer` (cheap) | design | cheap; Sol excepcional (`opencode-v2.md:200-206`) | Sol/high; paid |
| `skeptic` (cheap) | planning (review) | cheap; Sol para plano high-risk (`opencode-v2.md:200-206`) | paid; substituição do reviewer |

Casos proibidos globais (nunca roteáveis para modelo pago ou cheapen sensível): `security_sensitive`, `credentials/secrets`, `financial mutation`, `production write` sem autorização, `destructive/irreversible`, `control-plane`, `MCP execution` (herdados de `capability-routing.json:120-126` + `opencode-v2.md:252-254`).

## 6. Prova técnica do override vs limitação documentada

**Estado PROVADO (INV-99): NÃO há campo modelo hoje.**

- `New-OrchestrationNativeDispatchIntent` — `scripts/v3/lib/OrchestrationNativeDispatch.ps1:791-905`: assinatura completa examinada; params `TaskId, TaskExpectedRevision, Agent, PromptHash, Scope, AcceptanceCriteria, IdempotencyKey, Owner, OwnershipGeneration, BaseRevision, ExternalIdempotent, ExternalIdempotencyProof`. **Nenhum param de modelo.**
- Pipeline `Invoke-OrchestrationDispatchPipeline` — `scripts/v3/lib/OrchestrationDispatchPipeline.ps1:506` (`Invoke-OrchestrationDispatchPipeline`): bundle determinístico de scopes/grants/evidence; sem campo modelo.
- Reserva `select-model`: `OrchestrationDecisionProvider.ps1:423-436` (refusal `model-selection-reserved` em QID e alternativas) + `OrchestrationDecisionProvider.ps1:574-578` (filtro Jev); `jev-advisory-policy.json:44-56` (`cannot: select-model`) + `:89-100` (keywords `model, provider, variant, llm, gpt, Muse, sonnet, opus, haiku, select-model`).
- Prosa sem plumbing: `source/adapters/opencode-v2.md:51` ("override temporário no spawn") e `:56-64` (cotas Astra) descrevem policy/intenção; nenhum contrato carrega o override até o executor.

**Consequência normativa:** qualquer SPEC futura que proponha `model:` no DispatchIntent ou no contrato `subagent` DEVE antes provar, no runtime V2 exato (pin `source/registry/runtime-versions.json`), que a tool `subagent` aceita parâmetro de modelo por chamada. Sem essa prova, a alternativa segura §6.1 é obrigatória.

### 6.1 Alternativa segura (se override por chamada NÃO for provado)

1. Manter 3 slots estáticos (`planner/cheap/strong`, `models.jsonc:3-8`) como único mecanismo.
2. Escala = troca de AGENTE (ex. `coder` → `architect` para decisão dura), nunca troca de modelo — já suportado pelo CapabilityRouter Stage 1/2.
3. Escala de custo = troca de ESTRATÉGIA (reduzir fan-out, reuse-first, cheapen de escopo), nunca downgrade de reviewer/security (`execution-budget-policy.json` perfis + `opencode-v2.md` Governor).
4. Registrar `PROOF_ABSENT` em todo `ModelRoutingResult` até prova contrária; router permanece em shadow/record-only.

## 7. Benchmark (reproduzível — especificação do que o PLAN deve conter)

- Golden workflows #30 (os mesmos da v0.1.0-SPEC §24 itens 19–25: curto, SPEC+PLAN longo, failure→recovery, rotation, reuse, Jev-fallback, bloqueio seguro) executados com e sem proposta de modelo.
- ≥ 3 runs por workflow; métrica primária `cost-to-DONE` (tokens + wall-clock + escalations consumidas), secundárias `verified-success-rate, tokens-to-DONE, time-to-DONE, human-intervention-rate, jev-useful-call-rate` (taxonomia `...-v0.1.0-SPEC.md` §23).
- Critério de promoção: `cost-to-DONE` menor com `verified-success-rate` não inferior, em ≥ 2/3 runs, sem violação de cotas; reversão: qualquer violação de authority/cota/DONE ou `WRONG/SUBOPTIMAL` recorrente → volta ao baseline estático, sem debate.
- Detalhe operacional no PLAN (`MODEL-ROUTER-vNext-PLAN.md` §4).

## 8. Garantias

1. **Autonomia:** envelope inalterado (`...-v0.1.0-SPEC.md` §10–§11); router nunca cria `HUMAN_AUTHORITY_REQUIRED` novo nem dispensa existente.
2. **Permissões:** `permissions: [{subagent, *, deny}]` nos workers + `experimental.subagent_depth: 1` (`opencode.v2.json.tmpl:37-169`) inalterados; router não toca `agents{}`.
3. **Validação/DONE:** Evidence Contract + `Test-OrchestrationTaskCompletion` + `Complete-OrchestrationTask` inalterados; claim do router é input, nunca prova.
4. **Jev:** nunca autoriza, escolhe, altera policy ou escreve DONE (`jev-advisory-policy.json:44-56` + `...-v0.1.0-SPEC.md` §9 Jev NÃO lista).
5. **Custos (política — 3 orçamentos distintos):** (a) baseline = custo do modelo base atual (pago-atual), FORA do router — benchmark e fallback executam sobre ele sem autorização extra; (b) consultas adicionais do router/Jev pagas; (c) escalonamentos pagos. `max_paid_calls` conta SOMENTE (b)+(c) adicionais, default `0` (nenhuma ativação paga automática); (b)/(c) > 0 exige autorização explícita por ambiente, e sem autorização o fallback BLOQUEIA a chamada adicional e degrada ao baseline (não falha a task); (d) nenhuma dependência de Free permanente — baseline pago-atual continua funcionando sem router; (e) medir latência Jev por chamada (`request_budget_seconds: 30`, `jev-advisory-policy.json:9`) e latência do router separadamente; latência nunca bloqueia despacho (fallback determinístico).
6. **V1:** `LEGACY_FROZEN` — zero mudanças, zero regressão admitida.

## 9. Backlog faseado + dependências

| Fase futura | Contém | Depende de |
|---|---|---|
| F0 — Prova de override | Provar/refutar param modelo na tool `subagent` V2 no runtime pinado; registrar `PROOF` ou `PROOF_ABSENT` (§6) | #4 (runtime pin), #30 (golden workflows como harness) |
| F1 — Contratos record-only | `ModelRoutingRequest/Result` como tipos shadow, sem efeito no despacho | F0, #6 (DecisionProvider), #16 (preflight/dispatch) |
| F2 — Shadow eval | Router propõe, Planner ignora; telemetria `cost-to-DONE` comparada | F1, #48 (telemetria), #55 (outcomes) |
| F3 — Envelope ativo piloto | 1–2 classes baixo risco (ex. `trivial → cheap`) com cotas, kill switch | F2 + gate humano, #61 (budgets), #62 (DONE gate) |
| F4 — Expansão | demais classes da matriz §5, menos proibidos | F3 verde + #78 (security review policy) |

Dependências citadas: #6, #16, #4, #30, #48, #55, #61, #62, #78 (números da issue-tracker do programa; sem alteração de escopo deles por esta SPEC).

## 10. Critérios de aceite (desta SPEC de planejamento)

1. Limites §3 sem sobreposição Planner/CapabilityRouter/DecisionProvider-Jev/ModelRouter/Kernel/V2. ✔
2. Contratos §4 tipados com `user_model_override` preservado. ✔
3. Matriz §5 19 agentes + proibidos. ✔
4. Prova §6 (arquivo:linha reais) + alternativa segura. ✔
5. Benchmark §7 + PLAN §4 com `cost-to-DONE`, ≥3 runs, promoção/reversão. ✔ (no PLAN)
6. Garantias §8 (autonomia, permissões, DONE, Jev, V1 frozen). ✔
7. Custos §8 item 5 (sem pago automático, sem Free permanente, latência Jev). ✔
8. Backlog §9 + deps. ✔
9. INDEX intacto (§12). ✔

## 11. Divergências do padrão SPEC v0.1.0 (reporte honesto)

- O padrão v0.1.0 (`§6 INV`, `§24` 27 itens) pressupõe feature em implementação; esta SPEC é backlog sem implementação — §§ de "gate de release" e "fases de implementação" vivem SOMENTE no PLAN como fases futuras condicionais, não como compromisso.
- Sem `Revision date/Baseline commit` de implementação (nada foi alterado); a base factual é INV-99 + arquivos citados com linha.
- Nenhuma nova invariante `INV-xxx` é criada (evita colisão com a numeração ativa v0.1.0); garantias ficam no §8.

## 12. INDEX (decisão explícita: NÃO alterar)

`docs/specs/INDEX.md` permanece intacto nesta fase. A indexação (linha `MODEL-ROUTER` + status `draft-backlog`) é decisão do Planner no review — indexar agora implicaria promover backlog a ativo sem gate.
