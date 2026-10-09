# Capability Routing — Plano Revisado Fase 2F (2026-10-08)

Branch: `feat/advisory-routing-refinement-2026-10-08` (base `a9550c1`).
Modo: **SHADOW + ADVISORY** (inalterado). Sem promoção a Active nesta fase.

## 1. Objetivo

Resolver advisory-side as 4 divergências honestas do 2E
(P1/P3/P11/P12: resolver 2d-shadow-1 vs Planner), endurecer risco/MCP/skills
em casos-guia do operador e provar regressão 2D/2E verde — sem ativar routing,
sem trocar flags, sem tocar o Autonomous Core.

## 2. Base e compatibilidade (código atual)

- Resolver `2d-shadow-1` (`scripts/v3/lib/CapabilityResolver.ps1` via
  `scripts/v3/capability-resolve.ps1` + `scripts/v3/capability-profile-overlay.ps1`).
- Registry: `source/registry/capability-routing.json` (version 1),
  `capability-flags.json`, `capabilities-v2.json`, `mcp-profiles.json`,
  `skills-catalog.json`. **19 agentes** em `source/agents/*.md`
  (inclui `docs-manager`, `reviewer`, `debugger` — nenhum worker novo).
- Flags routing **OFF e inalteradas**: `capability_router.active/shadow`,
  `skill_routing`, `mcp_routing`, `adaptive_ranking`, `routing_telemetry`,
  `capability_reconciler`, `runtime_grant_enforcement.v1/v2`
  (gate `test-package-consistency.ps1` check 9 continua exigindo OFF).
- `resolver_version` **mantido em `2d-shadow-1`** (ver §6, adaptação A1).

## 3. Refinamentos (regras deterministas, sem LLM/rede)

| # | Mudança | Onde | Pilots/casos |
|---|---------|------|--------------|
| R1 | Nova regra `reviewer` (`review`, `pull request`), antes de architect/docs/coder | `capability-routing.json` agent_rules | P12→reviewer; `review pull request`→reviewer; `review architecture docs`→reviewer; `review release notes`→reviewer (LOW) |
| R2 | Nova regra `docs-manager` (setup guide, readme, user guide, runbook, lookup, procedure, release notes, changelog), antes de `researcher` | agent_rules | P1/P11→docs-manager; `write setup guide`/`write README`→docs-manager |
| R3 | `debugger` += `failing`, `fail` | agent_rules | P3→debugger; `investigate failing test`→debugger |
| R4 | `tester` += `checkout flow` (+ `needsE2E`) | agent_rules + `CapabilityResolver.ps1` | `test browser checkout flow`→tester/testing/playwright |
| R5 | Skill `systematic-debugging` += `fail` | `CapabilityResolver.ps1` | failing conta como debug; max 3, só ACTIVE, sem preencher slots |
| R6 | Financeiro: menção + verbo de execução → CRITICAL+deny; menção + sinal documental sem execução → LOW+allow; menção sem sinal documental → CRITICAL (conservador) | `CapabilityResolver.ps1` (+ triggers/deny descritivos no JSON) | `document Stripe refund procedure` LOW+allow; `execute customer refund`/`refund customer payment` CRITICAL+deny; N1 segue CRITICAL |
| R7 | Produção: `read` + `deployment/production logs` → LOW+allow sem `RISK_PRODUCTION_WRITE`; resto → HIGH+deny | `CapabilityResolver.ps1` | `read production deployment logs` LOW; `deploy production`/`delete production database` HIGH+deny |
| R8 | `docs-manager` no `allowedAgents` (agente existente, não inventado) | `CapabilityResolver.ps1` | override seguro continua possível |

Preservado: browser FULL (playwright + chrome-devtools) APPROVED só em
profiles apropriados (`testing`); nada de browser para `read CSS`,
`write README`, `review architecture docs`, `rename variable`;
Supabase/Neon só com evidência concreta (mencão sem prova → AMBIGUOUS, sem MCP);
nenhum MCP novo; nenhum `--slim` default; enforcement continua autoridade final
(resolver só recomenda `allow/deny`); zero bypass.

## 4. Corpus 2F (43 casos, gabarito independente)

`evidence/capabilities-phase-2f/shadow-corpus-2026-10-08.json`:
- **FIXTURE (30)**: casos-guia do operador (F01–F08) + risco/MCP/skills
  (F09–F30). Gabarito `operator-criteria` (critérios 2–6 da tarefa) ou
  `parity-2d` (comportamento 2D congelado, auto-verificado pela suíte).
- **REAL (13)**: replay dos pilots 2E. 11 com `task_summary` verbatim do
  ledger; 2 reconstruídos sem o artefato de paráfrase (R04/R13 — ver §6 A3).
  Gabarito `planner-2e` (decisão do Planner no ledger); os 9 inalterados são
  auto-verificados contra os JSONs 2E congelados.
- **NOT RUN**: Meu Ted (sem checkout, herdado 2E), ativação real de MCP e
  mutação real em produção (fora do escopo shadow).
- Nenhuma saída do Resolver foi usada como gabarito.

## 5. Métricas antes/depois (mesmos conjuntos)

- **Before** (ledger 2E congelado): agent 9/13, profile 11/13, over 0,
  under-unsafe 0, critical 0.
- **After** (suíte 2F live): replay 2E corrigido **13/13**
  (9 preservados + 4 corrigidos); corpus 2F **43/43**; comparables **19/19**
  (100% ≥ alvo 90%). Regressão 2D **372/372** via suíte própria; 2E **408/408**.
- **Não é claim de estabilidade produtiva** (amostra pequena: 43 casos +
  13 pilots). Recomendação: **CONTINUE_ADVISORY**; Active segue decisão do
  operador com mais dados reais.

## 6. Divergências e adaptações registradas

- **A1 — `resolver_version` mantido (`2d-shadow-1`)**: bump quebraria o
  contrato de regressão 2D (suíte 2D + CLI asserem `2d-shadow-1`). 2F é
  refinamento de regras sob a mesma linhagem; rastreio via este plano +
  corpus 2F + `note` do registry.
- **A2 — P1 (`lookup`) vs N2-2D (congelado `researcher`)**: textos quase
  idênticos; o 2D congelado exige N2=researcher, o operador exige
  P1=docs-manager. Distinção determinística: sinal de docs internas
  (`lookup`, `setup guide`, …) → docs-manager antes de `researcher`;
  `Read library docs … guide` (sem esse sinal) segue researcher. Residual
  advisory-only (ambos LOW/allow/sem ativação insegura).
- **A3 — R04/R13 reconstruídos**: os summaries do ledger contêm `runtime`,
  token que sob regras congeladas rotearia a debugger — incompatível com os
  outputs 2E armazenados (frontend-engineer). Inputs reais provadamente não
  tinham o token; corpus usa texto reconstruído, marcado em `input_note`.
- **A4 — R01 skills**: summary verbatim contém `version-specific` (prefixo
  `spec` → TDD); o input real não tinha o token (stored=verification).
  Eixo corrigido (agent) verificado; nuance documentada no caso.
- **A5 — profiles core em P1/P11 mantidos**: correção 2F é só no eixo agent
  (planner divergiu só nele); profile core + context7 já eram seguros
  (LOW, docs-only MCP). `review release notes` → reviewer (eixo review
  vence), risco LOW preservado (P2-4).
- **A6 — suíte 2E**: ajuste mínimo só nos 4 expects P1/P3/P11/P12, com
  re-resolução live a partir do ledger (JSONs históricos intactos).

## 7. Arquivos (menor mudança defensável)

- Novo: `docs/plans/CAPABILITY-ROUTING-PHASE-2F-PLAN.md` (este),
  `scripts/v3/lib/CapabilityRoutingPhase2F.tests.ps1`,
  `evidence/capabilities-phase-2f/` (corpus + results + metrics gerados).
- Edit: `source/registry/capability-routing.json` (regras/keywords,
  triggers e deny descritivos, note; version/mode/resolver_version intactos),
  `scripts/v3/lib/CapabilityResolver.ps1` (5 sinais: allowedAgents,
  fin-doc, prod-logs, needsE2E, skill fail),
  `scripts/v3/lib/CapabilityRealWorldPhase2E.tests.ps1` (só os 4 expects +
  bloco live com justificativa).
- **Não tocados**: flags, Autonomous Core (Goal/Task Kernel, Objective
  Runtime, DispatchPipeline, Watchdog), enforcement, overlay, MCPs,
  JSONs 2E/2D, `master` (sem commit direto; sem force push).

## 8. Riscos residuais

- Amostra pequena → sem claim produtivo; heurísticas de substring
  (`lookup`, `procedure`, `review`, `fail`, `run`) podem classificar demais
  em textos adversos — direção conservadora (deny/elevado) onde há efeito
  externo; tudo advisory-only.
- `run` como verbo financeiro casa prefixo `runtime` (só importa com menção
  financeira; conservador por desenho).
- DNS-lookup-like (`lookup` + `failure`) cai em debugger via `fail` antes de
  docs-manager (ordem documentada em R1/R2).

## 9. Validação

```powershell
powershell -NoProfile -File scripts/v3/lib/CapabilityRoutingPhase2F.tests.ps1
powershell -NoProfile -File scripts/v3/lib/CapabilityRealWorldPhase2E.tests.ps1
powershell -NoProfile -File tests/distribution/capability-routing-phase2d.tests.ps1
powershell -NoProfile -File scripts/test-package-consistency.ps1
git diff --check
```

## 10. Apêndice 2F-FIX-MUTATION-PRECEDENCE (2026-10-08, TASK_ID 2F-FIX-MUTATION-PRECEDENCE)

Review da Fase 2F apontou 2 findings MEDIUM + 1 LOW; correção mínima, sem
regressão dos casos já verdes:

- **MEDIUM produção mista**: a exceção de leitura de logs (`read` +
  `deployment/production logs`) anulava qualquer menção a produção, de modo
  que `delete production database and read production logs` caía para LOW.
  Fix: a exceção vale SOMENTE para leitura exclusiva — com verbo de mutação
  em produção, volta a HIGH + deny + `RISK_PRODUCTION_WRITE`
  (`CapabilityResolver.ps1`: `$isProdMutation`).
- **MEDIUM financeira mista**: a exceção documental (`document/procedure`)
  anulava a menção financeira, de modo que `refund customer payment
  following the procedure` caía para LOW. Fix: a exceção vale SOMENTE para
  intenção exclusivamente documental — sem verbo de execução E sem alvo
  operacional (`$isFinancialOpTarget`). Direção conservadora em ambiguidade:
  `document customer refund policy` fica CRITICAL (aceito).
- **Restrição técnica**: `Test-ResolverBlobHas` faz prefix-match por token
  (`deploy` casa com `deployment`), por isso os verbos de mutação de
  produção (`deploy/delete/destroy/drop/update/upgrade/publish/rollout/
  restart/scale/stop/start/reboot/push/apply`) e o alvo financeiro
  operacional (`customer/payment(s)/invoice(s)/subscription(s)/card(s)`)
  usam comparação por token exato (nova `Test-ResolverBlobHasExact`).
  `read production deployment logs` segue LOW + allow (sem mutação exata).
- **LOW metrics**: a suíte gravava results/metrics antes do veredito final,
  com aparência de sucesso mesmo com FAIL. Fix: aprovação computada por caso
  (`$failedCases`) + escrita de evidence SOMENTE quando verde (`$fail -eq 0`);
  com FAIL, nada é gravado (evidence anterior preservada, sem aparência de
  sucesso) e o exit é != 0 (provado via probe com falha sintética: FAIL 1,
  mtimes inalterados).
- **Casos mistos** (5) como testes independentes na suíte 2F, com expectativa
  própria (HIGH/CRITICAL + deny + reason): 3 de produção + 2 financeiros.
- **Preservados**: `review release notes` LOW; `read production deployment
  logs` LOW + allow; `document Stripe refund procedure` LOW + allow sem
  stripe-mcp; `execute customer refund` / `refund customer payment`
  CRITICAL + deny; `deploy production` / `delete production database`
  HIGH + deny; P1/P3/P11/P12; guias F01–F08. Corpus segue 43/43; comparables
  no alvo; 2E 408/408, 2D 372/0, package-consistency 16/0.
- **Fora do escopo, intocado**: flags, Autonomous Core, JSONs 2E, advisory-only.

## 10.2. Apêndice 2F-FIX-EXCEPTION-ALLOWLIST (2026-10-08, TASK_ID 2F-FIX-EXCEPTION-ALLOWLIST)

Estratégia nova contra bypasses residuais do re-review (2 MEDIUM + 1 MEDIA):
em vez de ampliar blocklists de verbos (sempre incompletas), as exceções
foram restringidas à intenção exclusivamente documental/leitura,
positivamente reconhecida; tarefa mista ou incerta => classificação
conservadora:

- **Produção**: `$isProdMutation` ampliado para flexões por token exato
  (deploy/delete/truncate/destroy/drop/update/upgrade/publish/rollout/
  restart/scale/stop/start/reboot/push/apply/trigger/migrate + flexões).
  `release` fora da lista (preserva `review release notes` LOW) e nada que
  case com `deployment` (token exato `deployment` segue leitura).
  Novos casos HIGH + deny + `RISK_PRODUCTION_WRITE`: `deploying production
  release and read deployment logs`, `truncate production database and read
  production logs`, `trigger production deployment`.
- **Financeiro**: precedência posicional por tokens
  (`Get-ResolverFirstTokenIndex`): exceção documental SOMENTE quando o
  primeiro verbo documental (document/procedure/explain/describe/draft/
  write + flexões) precede qualquer sinal operacional (execute/process/
  perform/run/initiate/approve/confirm/submit/transfer/charge/pay/payout/
  refund + flexões) E não há alvo operacional (customer/payment/invoice/
  subscription/card/order + plural). Novos casos CRITICAL + deny: `refund
  following the procedure` (refund antes de procedure), `refund order 123
  and document procedure` (refund primeiro + alvo order), `document
  procedure and refund customer payment` (doc primeiro MAS alvo customer).
- **Preservados**: `document Stripe refund procedure` LOW + allow
  (document < refund, sem alvo); todos os verdes do §10.
- **Casos mistos** na suíte 2F sobem de 5 para 11 (6 produção + 5
  financeiros); corpus segue 43/43; 2E 408/408, 2D 372/0.

## 10.3. Apendice 2F-FIX-DEBUGGER-R5R6 (2026-10-08, TASK_ID 2F-FIX-DEBUGGER-R5R6)

Terceira tentativa, estrategia nova - em vez de ampliar blocklists de verbos
(sempre incompletas), as excecoes passaram a ser reconhecidas por FORMA
TEXTUAL FECHADA e os sinais de risco passaram a ser calculados somente sobre
o texto da tarefa. Nao ha alegacao de compreensao semantica: sao regras
lexicais deterministas, com limites conhecidos listados ao final.

- **R5 (exec-veto)**: `document procedure and execute Stripe refund` =>
  CRITICAL + deny. Verbo de execucao inequivoco em QUALQUER posicao
  (execute/process/perform/run/initiate/approve/confirm/submit/transfer/
  charge/pay/payout + flexoes, tokens exatos) veta a excecao documental.
  `refund` fica FORA do conjunto (ambiguo: substantivo ou verbo) e continua
  tratado por clausula + alvo.
- **R5b (clausulas)**: `document procedure and refund` => CRITICAL + deny.
  O texto da tarefa e dividido em clausulas por `and`/`then`/`;`; a excecao
  documental vale SOMENTE se TODA clausula com mencao financeira contiver
  verbo documental proprio (document/documents/documented/documenting,
  explain-*, describe-*, draft-*, write-*) E nao houver exec-veto (R5) nem
  alvo operacional (customer(s)/payment(s)/invoice(s)/subscription(s)/
  card(s)/order(s)). `procedure` sozinho NAO conta como verbo documental
  (e substantivo). A precedencia posicional do 10.2 foi SUBSTITUIDA por
  essa regra de clausulas (mais forte: cobre as duas ordens); o helper
  `Get-ResolverFirstTokenIndex` foi removido por ficar sem uso.
- **R6 (forma fechada de logs-read)**: `remove production database and read
  production logs` => HIGH + deny + RISK_PRODUCTION_WRITE. A excecao de
  leitura de logs passa a exigir que TODO token do texto da tarefa seja:
  verbo de leitura (read/reads/reading/review/reviews/reviewing/lookup/
  analyze/summarize/show/list/view/monitor/check/tail/fetch/get/display +
  flexoes, tokens exatos), descritor (production/producao/deployment/prod),
  `logs` ou filler (the/a/an/of/for/to/in/on/from/with/and/last/latest/
  recent/first/app/application/service/server/lines). Qualquer token de
  conteudo fora da forma => sem excecao => HIGH + deny. `deployment` e
  descritor (nao flexao de deploy); `release` NAO e verbo de mutacao nem
  descritor da forma - `review release notes` continua LOW por nao ter
  mencao de producao. `remove` NAO entrou em blocklist: a forma fechada ja
  o exclui. A lista de mutacao do 10.2 segue como veto redundante.
- **Descontaminacao por metadados**: `$blob` (task + task_class +
  risk_context + stack + stacks detectados) segue inalterado para sinais de
  agentes/skills/perfis/capabilities, mas os sinais de RISCO (isFinancial,
  isProd e as excecoes doc/logs-read) passaram a ser calculados sobre
  `$riskText` (texto da tarefa) com `$riskCtxText` (risk_context explicito)
  atuando apenas como OR de elevacao. task_class/stack nao podem fornecer
  sinais que REBAIXEM risco (ex.: task_class `document procedure` nao cria
  verbo documental; stack `stripe` nao cria mencao financeira; task_class
  `documentation` nao cria excecao para R5/R6).
- **Preservados**: `review release notes` LOW; `read production deployment
  logs` LOW + allow; `document Stripe refund procedure` LOW + allow sem
  stripe-mcp; `execute customer refund` / `refund customer payment` /
  `process stripe payout` / N1 (stripe element bug) CRITICAL + deny; os 11
  mistos do 10.2; P1/P3/P11/P12; guias F01-F08. Corpus segue 43/43.
- **Suíte 2F**: casos mistos sobem para 14 (7 producao + 7 financeira:
  R5/R5b/R6 incluidos) + 9 casos dedicados de descontaminacao por metadados
  (task_class/stack nao rebaixam; risk_context eleva; metadata neutro).
  Contagem 2F 976/0; 2E 408/408; 2D 372/0; package-consistency 16/0.
- **Limites conhecidos (honestos, heuristicas lexicais)**: `document the
  refund process` segue CRITICAL (`process` entra no veto); `read production
  log` (singular) nao casa a forma (conservador); fillers/descriptores sao
  lista fechada (sem `or`/`then`/`log` singular); sinonimos fora do corpus
  (`reembolso`, `estorno`) nao são mencao; proxy text-only, nao semantica -
  a decisao continua advisory/shadow e promotion segue sendo decisao humana
  com evidencia.

## 10.4. Apendice 2F-FIX-CLAUSE-SEPARATORS (2026-10-08, TASK_ID 2F-FIX-CLAUSE-SEPARATORS)

Fechamento da fronteira de clausulas da excecao documental financeira. Antes
só `and`/`then`/`;` separavam clausulas; `document procedure. refund` e
`document procedure, refund` caiam na mesma clausula e recebiam LOW indevido.

- **Separadores** (`scripts/v3/lib/CapabilityResolver.ps1`, bloco
  `$finClauses`): alem de `and`/`then`/`;`, passam a separar clausulas `.`,
  `,`, `:`, `!?`, `but` e quebra de linha. Clausulas VAZIAS apos o split sao
  ignoradas: ponto final isolado (`document Stripe refund procedure.`) nao
  cria clausula e a excecao segue valendo (LOW + allow).
- **FRONTEIRA (regra declarada, feita valer no codigo)**: a excecao
  documental financeira so vale em clausula UNICA nao-vazia que contenha
  mencao financeira (refund/payout/pagamento/cobranca/stripe/financial) E
  verbo documental proprio (document/explain/describe/draft/write + flexoes;
  `procedure` sozinho NAO conta), sem exec-veto (R5) e sem alvo operacional
  (customer/payment/invoice/subscription/card/order + plural). Qualquer
  tarefa com mencao financeira distribuida em 2+ clausulas nao-vazias cai em
  CRITICAL + deny (conservador: nao ha alegacao semantica, apenas forma
  textual fechada).
- **Regressoes novas** (`scripts/v3/lib/CapabilityRoutingPhase2F.tests.ps1`,
  bloco `$finClauseSep`, expectativa propria): `document procedure. refund`
  => CRITICAL + deny; `document procedure, refund` => CRITICAL + deny;
  guard verde `document Stripe refund procedure.` => LOW + allow (prova que
  clausula vazia e ignorada).
- **Preservados**: F10 sem pontuacao LOW; R5/R5b; R1-R4; 11+ mistos; verdes
  base; P1/P3/P11/P12; skills/MCP; metrics gate (evidence so gravada com
  suite verde). Contagens: 2F 985/0 (era 976/0; +9 asserts), 2E 408/408,
  2D 372/0, package-consistency 16/0. Flags/Core/JSONs intactos;
  deterministico; advisory-only.
- **Residual honesto**: `or` e `with` ficam FORA dos separadores.
  `document refund or charge procedures` cai no exec-veto via `charge`;
  demais combinacoes com `or`/`with` seguem como residual documentado
  (heuristica lexical, proxy text-only - promotion continua sendo decisao
  humana com evidencia).

## 10.5. Apendice 2F-FIX-P2-WRITE-VERB (2026-10-08, TASK_ID 2F-FIX-P2-WRITE-VERB)

Finding P2 do Codex no PR #45: `write` sozinho satisfazia o conjunto de
verbos documentais financeiros (`$finDocVerbWords`), entao `write Stripe
refund script` e `write financial transaction code` recebiam LOW + allow
indevidos. `write`/`writes`/`writing`/`written` sairam do conjunto: `write`
sozinho nao prova intencao documental (pode ser criacao de CODIGO
financeiro). Verbo documental proprio passa a ser somente
document/explain/describe/draft + flexoes.

- **Regressoes novas** (`scripts/v3/lib/CapabilityRoutingPhase2F.tests.ps1`,
  bloco `$finWriteVerb`, expectativa propria): `write Stripe refund script`
  => CRITICAL + deny; `write financial transaction code` => CRITICAL + deny.
- **Preservados**: `document Stripe refund procedure` LOW + allow (F10 do
  corpus, usa `document`); `write setup guide`/`write README` seguem LOW e
  docs-manager (sem mencao financeira, regra de agente inalterada); F10 sem
  pontuacao LOW; R5/R5b; fronteira de clausulas 10.4; verdes base;
  P1/P3/P11/P12. Corpus 2F/2D/2E intactos (nenhum caso verde dependia de
  `write` financeiro para LOW - verificado por varredura dos corpus).
- **Escopo**: somente a lista de verbos documentais financeiros em
  `scripts/v3/lib/CapabilityResolver.ps1` + 2 regressoes + esta nota.
  Agentes, matcher, flags, Core e JSONs intactos.
