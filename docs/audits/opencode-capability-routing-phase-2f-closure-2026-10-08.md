# Closure — Capability Routing Phase 2F (2026-10-08)

Branch: `feat/advisory-routing-refinement-2026-10-08` (base `a9550c1`).
Veredito: **PASS (SHADOW + ADVISORY; Active NÃO promovido; recomendação CONTINUE_ADVISORY)**.

Plano canônico: `docs/plans/CAPABILITY-ROUTING-PHASE-2F-PLAN.md` (§1–§10.4).
Formato segue o closure 2E (`docs/audits/opencode-advisory-git-governance-phase-2e-closure-2026-10-07.md`).

## 1. Objetivo e Gates de Conclusão

Objetivo (plano §1): resolver advisory-side as 4 divergências honestas do 2E
(P1/P3/P11/P12: resolver `2d-shadow-1` vs Planner), endurecer risco/MCP/skills
nos casos-guia do operador e provar regressão 2D/2E verde — **sem ativar
routing, sem trocar flags, sem tocar o Autonomous Core**.

Nota de rastreabilidade: os gates abaixo (G1–G7) são a decupação verificável do
objetivo do plano §1 e dos critérios de gabarito §4–§7; o plano não os nomeia
nominalmente ("G1..G7"), portanto cada gate é ancorado a um fato verificável
(métrica, diff ou execução de suíte), não a rótulo inventado.

| Gate | Estado | Evidência |
|------|--------|-----------|
| G1 — Divergências 2E resolvidas advisory-side (P1/P11 → docs-manager, P3 → debugger, P12 → reviewer) | **PASS** | replay_2e 13/13 (9 preservados + 4 corrigidos); asserts suíte 2F + bloco live 2E |
| G2 — Override seguro aplicável a `docs-manager` (fecha gap da allowlist) | **PASS** | `$allowedAgents` += `docs-manager` (R8), `scripts/v3/lib/CapabilityResolver.ps1` |
| G3 — Risco: documental/leitura LOW vs execução/mutação CRITICAL/HIGH, com exceções conservadoras por forma fechada | **PASS** | sinais fin-doc/prod-logs + §10–§10.4; 14 casos mistos + fronteira de cláusulas; 43/43 |
| G4 — Contenção MCP/skills (browser só em `testing`; supabase/neon só com evidência; 0 MCP novo; skills ≤3, só ACTIVE, `fail`→systematic-debugging) | **PASS** | `not_expected` verificado em 43/43 casos; asserts de contensão |
| G5 — Corpus e métricas: corpus_2f 43/43; comparables 19/19 (≥ alvo 90%) | **PASS** | `shadow-results`/`shadow-corpus`/`metrics` 2F; asserts `comparables >= 19` e `agreement >= 90%` |
| G6 — Regressão e consistência verdes | **PASS** | 2E 408/408; 2D 372/0; package-consistency 16/0 (check 9 exige flags routing OFF) |
| G7 — Escopo preservado (não-regressão de política): flags OFF, Autonomous Core intacto, JSONs 2E/2D intactos, `resolver_version` intacto, shadow/advisory, 0 bypass | **PASS** | `git diff --name-only` (só 4 arquivos); registry `note`; consistency 16/0 |

## 2. Diagnóstico e Causa-Raiz

**Causa-raiz inicial (baseline 2E, resolver `2d-shadow-1`):**

1. Roteamento por *first-keyword-match* (plano §3, `agent_rules`) **sem regra
   `reviewer`** e **sem regra `docs-manager`**: `review pull request` (P12) e a
   consulta/autoria de docs internos (P1 `lookup`, P11 setup guide) caíam no
   default `coder`/`researcher`. Consequência: 3 das 4 divergências do 2E.
2. Ausência do sinal `failing`/`fail` como debug: P3 (`investigate failing test`)
   roteava a `coder`, não a `debugger` (4ª divergência).
3. Allowlist de override `$allowedAgents` **não continha `docs-manager`**:
   mesmo quando o Planner decidia `docs-manager`, o override "seguro" do resolver
   o bloqueava (gap de allowlist).
4. Gap de risco tratado depois, por evidência parcial dos reviews: as exceções
   (leitura de logs de produção; menção financeira documental) foram sendo
   refinadas porque blocklists de verbos são sempre incompletas. Evolução:
   - **§10 (fix1, blocklist mínima + precedência)**: `$isProdMutation` e
     `$isFinancialOpTarget`; `Test-ResolverBlobHasExact` (tokens exatos, evita
     prefixo `deploy`↔`deployment`).
   - **§10.2 (fix2, allowlist/posicional → debugger `2F-DEBUG-EXCEPTIONS`)**:
     exceções restritas à intenção exclusivamente documental/leitura,
     reconhecida positivamente; tarefa mista/incerta ⇒ conservadora.
   - **§10.3 (fix3, exec-veto/cláusulas/forma-fechada/descontaminação)**:
     veto de execução em qualquer posição; divisão em cláusulas; forma textual
     fechada de logs-read; sinais de risco sobre o texto da tarefa
     (`$riskText`/`$riskTokens`), metadata só eleva.
   - **§10.4 (clause-separators)**: fronteira de cláusulas fechada (`. , : ; ! ?`
     `and`/`then`/`but` + newline); cláusula vazia ignorada.

## 3. Mudanças (menor mudança defensável)

Modificados (tracked, confirmado por `git diff --name-only`):

- `source/registry/capability-routing.json` (+17): regras `agent_rules` R1
  (`reviewer`: `review`/`pull request`, antes de architect/docs/coder), R2
  (`docs-manager`: setup guide/readme/user guide/runbook/lookup/procedure/
  release notes/changelog, antes de `researcher`), R3 (`debugger` +=
  `failing`/`fail`), R4 (`tester` += `checkout flow`); `skill_rules` +=
  (`fail`→systematic-debugging); `triggers`/`deny_rules` descritivos de risco
  (fin-doc LOW, prod-logs LOW, menção sem sinal documental CRITICAL); `note`
  atualizada. **`version`/`mode`/`resolver_version` intactos** (`2d-shadow-1`).
- `scripts/v3/lib/CapabilityResolver.ps1` (+103): `Test-ResolverBlobHasExact`;
  `$riskText`/`$riskCtxText`/`$riskTokens` (descontaminação por metadados);
  `$needsE2E` += `checkout flow`; sinais financeiros (`$isFinancialMention`,
  `$finExecVeto`, `$finDocVerbWords`, `$isFinancialOpTarget`, `$finClauses`,
  `$finDocException`); sinais de produção (`$isProdMention`, `$logsReadVerbs`
  /`$logsDescriptors`/`$logsFillers`, `$logsFormShaped`, `$isProdLogsRead`,
  `$isProdMutation`); `$allowedAgents` += `docs-manager` (R8); skills += `fail`.
- `scripts/v3/lib/CapabilityRealWorldPhase2E.tests.ps1` (+55): **somente** os 4
  expects P1/P3/P11/P12 corrigidos, com re-resolução **live** a partir do
  `task_summary`/`task_class` do ledger; os outros 9 pilots continuam comparados
  aos JSONs históricos (regressão). JSONs de `evidence/capabilities-phase-2e/`
  **não** foram alterados.
- `docs/plans/CAPABILITY-ROUTING-PHASE-2F-PLAN.md` (novo): plano + apêndices
  §10–§10.4.
- `scripts/v3/lib/CapabilityRoutingPhase2F.tests.ps1` (novo): suíte do corpus
  2F.
- `evidence/capabilities-phase-2f/` (novo): `shadow-corpus-2026-10-08.json`
  (43 casos), `shadow-results-2026-10-08.json` (43), `metrics-2026-10-08.json`;
  todos `mode: shadow`, `resolver_version: 2d-shadow-1`, gerados pela suíte
  (gravados só quando verde — §10 fix LOW).
- `.gitignore` (1 linha): exceção `!evidence/capabilities-phase-2f/`.

Não tocados (confirmado): flags (`capability-flags.json` e as demais
`capability-*.json`, `mcp-profiles.json`, `skills-catalog.json`), Autonomous Core
(Goal/Task Kernel, Objective Runtime, DispatchPipeline, Watchdog), enforcement,
overlay, JSONs 2E/2D, `master` (sem commit direto; sem force-push).

## 4. Histórico de Review

Rastreabilidade: os fixes de cada rodada estão ancorados como apêndices
versionados do plano (§10–§10.4) e nas suítes; o APPROVED duplo (round4) é o
estado final. Busca em `evidence/capabilities-phase-2f/` **não** retorna
artifact de review/feedback — o registro vivo deste ciclo é o plano + este
closure (honestidade de procedência).

- **Round 1** — 2 MEDIUM + 1 LOW ⇒ **§10 (fix1 `2F-FIX-MUTATION-PRECEDENCE`)**:
  produção mista (`delete production database and read production logs` caía a
  LOW) e financeira mista (`refund customer payment following the procedure`) →
  exceções valem só para intenção exclusiva; LOW metrics → evidence gravada só
  com suíte verde.
- **Round 2** — 2 MEDIUM + 1 MEDIA (residuais) ⇒ **debugger `2F-DEBUG-EXCEPTIONS`**
  ⇒ **§10.2 (fix2 `2F-FIX-EXCEPTION-ALLOWLIST`)**: troca blocklists (sempre
  incompletas) por allowlist positiva/posicional.
- **Round 3** — 2 MEDIUM (R5/R6, pontuação/score de risco) ⇒ **§10.3 (fix3
  `2F-FIX-DEBUGGER-R5R6`)**: exec-veto + cláusulas + forma textual fechada +
  descontaminação por metadados; complementado por **§10.4
  (`2F-FIX-CLAUSE-SEPARATORS`)** fechando a fronteira `.`/`,`.
- **Round 4** — **APPROVED duplo** (`reviewer` + `security-reviewer`).
  **Tester PASS em todas as rodadas.**

## 5. Métricas Antes/Depois

- **Antes** (ledger 2E congelado, `metrics.before`): agent **9/13**, profile
  **11/13**; over-activation 0, under-activation insegura 0, critical routing
  mistakes 0.
- **Depois** (suíte 2F live): replay_2e **13/13** (9 preservados via paridade
  `2E-stored` + 4 corrigidos para o Planner 2E: P1/P11 docs-manager, P3
  debugger, P12 reviewer); corpus_2f **43/43**; comparables **19/19**
  (= 6 [2D-corpus 3 + 2D-inline 3] + 13 [2E-stored 9 + 2E-planner 4]; 100% ≥
  alvo 90%); over-activation **0**, critical routing mistakes **0**, bypass
  **0**.
  - Fundamentação de over/critical/bypass = 0: todos os 43 casos têm
    `not_expected` verificado por caso (`nada do not_expected ativo`) e `perm`
    conferido por caso (`allow`/`deny` conforme gabarito); 43/43 verdes ⇒ nenhuma
    ativação proibida, nenhum caso de efeito externo em `allow`, nenhuma exceção
    rebaixando um execute/mutação para bypass.
- **Ressalva explícita** (`metrics.stability`): concordância **não** é prova de
  estabilidade produtiva — amostra pequena (43 casos + 13 pilots). Active
  promotion segue sendo decisão do operador com mais dados reais
  (**CONTINUE_ADVISORY**).

## 6. Testes (contagens, executadas nesta sessão 2026-10-08, exit 0)

| Suíte | Resultado |
|-------|-----------|
| `CapabilityRoutingPhase2F.tests.ps1` (2F) | **985 / 0** |
| `CapabilityRealWorldPhase2E.tests.ps1` (2E) | **408 / 408** |
| `capability-routing-phase2d.tests.ps1` (2D) | **372 / 0** |
| `test-package-consistency.ps1` (consistency) | **16 / 0** (total 16) |
| `capability-registry-v2.tests.ps1` (registry-v2) | **48 / 0** |
| `mcp-profiles.tests.ps1` (mcp-profiles) | **8 / 0** |
| `skills-catalog.tests.ps1` (skills-catalog) | **18 / 0** |
| `capability-planning.tests.ps1` (capability-planning) | **12 / 0** |

`git diff --check` limpo (ver §9).

## 7. Riscos Residuais (honestos)

- **Lexical, não semântico**: as regras são *proxy text-only* por forma textual
  fechada (tokens/cláusulas); não há alegação de compreensão semântica. A
  decisão continua advisory/shadow; promotion é decisão humana com evidência.
- **`or`/`with` fora dos separadores de cláusula** (§10.4): combinacoes com
  `or`/`with` seguem como residual documentado.
- **`document the refund process`**: `process` entra no veto de execução ⇒
  **CRITICAL conservador** (aceito; não é falso negativo de segurança).
- **`read production log` (singular)**: não casa a forma fechada (exige token
  `logs`) ⇒ conservador (não vira LOW automático).
- **Over-classificação possível**: substrings (`review`, `procedure`, `fail`)
  podem classificar demais em textos adversos — direção conservadora
  (deny/elevado) onde há efeito externo; fillers/descriptores são lista fechada.
- **Sinônimos fora do corpus** (ex.: `reembolso`, `estorno`) não são menção
  financeira pelas regras atuais.
- **Fronteira real = enforcement**: o resolver só recomenda `allow`/`deny`;
  enforcement e a decisão continuam com o Planner/Kernel. Nada aqui ativa MCP,
  não altera permissões efetivas e não cria capacidade nova.

## 8. Veredito, Arquitetura e Recomendação

**Phase 2F: PASS (advisory).**

- Resolver: **REFINED** (regras de agente/skill/risco refinadas) sob a mesma
  linhagem, `resolver_version` mantido em `2d-shadow-1` (contrato de regressão
  2D preservado), operando em **shadow**.
- Advisory: **READY / CONTINUE_ADVISORY** — recomendações conferidas contra
  corpus/gabarito independente; sem promoção automática.
- **Active: HOLD** — promoção é decisão futura do operador com mais dados reais.
- **Flags: UNCHANGED (OFF)** — `capability_router.active/shadow`,
  `skill_routing`, `mcp_routing`, `adaptive_ranking`, `routing_telemetry`,
  `capability_reconciler`, `runtime_grant_enforcement.v1/v2` (check 9 de
  package-consistency exige OFF; 16/0).
- **Planner/Kernel authority: UNCHANGED** — Autonomous Core intocado; resolver é
  consultivo.

**Recomendação: CONTINUE_ADVISORY** (sem promoção automática a Active).

## 9. Git / PR / CI

- Branch `feat/advisory-routing-refinement-2026-10-08`; HEAD `a9550c1`; base
  `a9550c1`. Arquivos novos: `docs/plans/`, `evidence/capabilities-phase-2f/`,
  `scripts/v3/lib/CapabilityRoutingPhase2F.tests.ps1`; modificados:
  `.gitignore`, `scripts/v3/lib/CapabilityRealWorldPhase2E.tests.ps1`,
  `scripts/v3/lib/CapabilityResolver.ps1`,
  `source/registry/capability-routing.json`.
- `git diff --check`: **limpo**.
- **PR: PENDENTE** (não aberto por esta fase).
- **CI: PENDENTE** (a executar no PR; nomes reais dos checks conforme a policy
  de git lifecycle; resultado de SHA anterior nunca reutilizado como prova do
  SHA atual).
- **Merge: PENDENTE** (método `--merge` padrão, sem squash/rewrite).

> Estado PR/CI/merge registrado no momento da escrita; conclusão (abertura do PR,
> resultado de CI, hash de merge) é responsabilidade do Planner e entra por
> follow-up dentro do PR — nunca por commit direto em `master`.

## 10. Evidência (arquivos)

- `evidence/capabilities-phase-2f/shadow-corpus-2026-10-08.json` — 43 casos
  (FIXTURE 30: operator-criteria 24 + parity-2d 6; REAL 13: planner-2e);
  `gabarito` independente, `expected`/`not_expected` por caso, `coverage.not_run`
  (Meu Ted, ativação real de MCP, mutação real em produção).
- `evidence/capabilities-phase-2f/shadow-results-2026-10-08.json` — 43 resoluções
  shadow (`2d-shadow-1`).
- `evidence/capabilities-phase-2f/metrics-2026-10-08.json` — before/after,
  flags, stability/não-claim.
- `docs/plans/CAPABILITY-ROUTING-PHASE-2F-PLAN.md` (§1–§10.4).

## 11. Veredito Final

**Phase 2F: PASS (SHADOW + ADVISORY).** Critérios atendidos: 4 divergências 2E
resolvidas advisory-side (replay 13/13 = 9 preservados + 4 corrigidos) + exceções
de risco conservadoras por forma fechada/cláusulas/descontaminação (§10–§10.4,
com participação do debugger `2F-DEBUG-EXCEPTIONS`) + contenção MCP/skills
(0 over-activation/critical/bypass; 0 MCP novo; browser só em `testing`) +
regressão 2E 408/408, 2D 372/0, consistency 16/0 (+ registry-v2 48, mcp-profiles
8, skills-catalog 18, capability-planning 12) + corpus 43/43 e comparables
19/19 (≥ 90%) + flags OFF/Autonomous Core/JSONs 2E/2D intactos + review
APPROVED duplo (round4) com tester PASS em todas as rodadas. Arquitetura final:
**SHADOW + ADVISORY**; **Active HOLD**; recomendação **CONTINUE_ADVISORY**.
Ressalva mantida: amostra pequena, sem claim de estabilidade produtiva.
Pendências: PR/CI/merge (a cargo do Planner).
