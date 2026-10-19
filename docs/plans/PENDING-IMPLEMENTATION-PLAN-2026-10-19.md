# Plano — Implementação das pendências documentais (2026-10-19)

Plano de execução da rodada aberta pelo inventário de 2026-10-19. Cinco frentes
escolhidas pelo operador: reconciliação documental, wiring produtivo do Planner
+ SETTLE, enforcement, MCP→subagent/S6 e RR-E2E-21.

- Baseline: `origin/master` = `1cbeb38` (merge #128; tag `v0.2.0` publicada).
- Branch desta frente: `docs/reconcile-status-2026-10-19`.
- Inventário de referência: análise read-only de 2026-10-19 (4 exploradores);
  evidências citadas por arquivo nos respectivos planos de fase.

## Invariantes e não-objetivos

- Nenhuma flag OFF é ativada sem evidência `exact-binary-live` + decisão do
  operador; nenhum claim de enforcement sem prova no binário real.
- Registros históricos de evidência não são reescritos; apenas notas datadas
  aditivas ou correções factuais em docs vivas.
- Config user-owned (`opencode.json` vivo, DE22307F) e segredos não são tocados.
- Tudo em branch + PR com CI; sem bypass, sem force-push, sem commit direto.
- Quota de modelo/provider só com aprovação explícita por frente, com orçamento
  declarado antes de cada run.

## F0 — Reconciliação documental (W1)

Objetivo: eliminar leitura estática enganosa sem reescrever história.

- `program-status.json`: adicionar bloco `update_2026_10_19` (release 0.2.0
  publicada, RR-20 blocked-critério-novo, 3 pass-real 16/17/19, pendências
  futuras) sem tocar em `closure_2026_10_06`/`update_2026_10_08`.
- `pae-traceability.json`: adicionar `snapshot_note` aditivo apontando para o
  status vivo (snapshot 2026-10-03; flags ativas desde 2026-10-04).
- `source/registry/runtimes.json`: campo aditivo de ponte para o pin canônico
  (`runtime-versions.json`), sem alterar `validated_version` histórico — desde
  que não quebre suites do registry.
- `docs/TROUBLESHOOTING.md`: S5 mergeado (PR #118) e cabeçalho do programa
  atualizado (gate PASS 2026-10-06; rodada 0.2.0 PARTIAL).
- `README.md`: tag `v0.2.0` publicada; precisão sobre `experimental.policies`
  (HOLD Phase 5) e lane CI V2 (verificar estado real no workflow).
- `docs/ARCHITECTURE.md`: corrigir nota de S5 fora do master (S5 mergeado em
  `c9e12d8`, confirmado por `git branch --contains`).

Aceite: JSONs parseiam; diffs preservam blocos datados; correções factuais
citam fonte; `scripts/test-package-consistency.ps1` verde no ambiente
disponível; reviewer independente APPROVED.

## F1 — Wiring produtivo do Planner + SETTLE (W2)

Fatias (da exploração de 2026-10-19; dependências `S1<S2<S3<S4<S6`, `S5`
paralela a `S1-S2`):

- S1: bridge CLI (argv/JSON sem shell interpolada) + hook de CLAIM deny-only.
- S2: owner único do SETTLE; liquidação canônica kernel-side com revalidação de
  ownership/generation/revision; estados candidate/persisted/verified/advanced.
- S3: ADVANCE/VERIFY no loop Planner (consome settlement, checkpoint,
  CONTINUE/RETRY/REPLAN; `TASK_DONE != OBJECTIVE_DONE`).
- S4: recovery por sessão substituta com ação atribuída; ambíguo nunca repete.
- S5: grants de origem + projeção deny-only + fail-closed sem bridge.
- S6: E2E 3 fases runtime-real (2.0.23) com Reviewer.

Gates: decisão de owner do SETTLE é `AUTHORITY_CHANGE` — Planner decide com
memo de architect; cada fatia passa por reviewer + security quando tocar
autoridade; plugin ausente/unload/ordem = BLOCK; flags existentes permanecem
como estão até evidência.

Aceite por fatia: suite dedicada verde em PS5.1 e PS7 + teste adversarial do
caminho de recusa; evidência em `evidence/v3.1/runtime-reliability/`.

## F2 — Enforcement (W4, última por risco)

Fatias (da exploração de 2026-10-19), cada uma com gate `exact-binary-live`:

- S1: budget observável → interrupção kernel-side (deadline/NO_PROGRESS →
  kill CIM+JobObject pinado) em fixture isolada.
- S2: deny `/shell` determinístico (overlay + per-sessão → recusa observável).
- S3: `experimental.policies` hard-deny (deny vence allow).
- S4: step-limits nativos derivados do budget canônico.
- S5: background-subagents bounded com reconciliação kernel.
- S6: evidência append-only com hash canônico e `v1_fallback` declarado.

Invariantes: nenhum hard-deny antes de prova no binário exato; `ask`/glob não
contam como bloqueio; ativar flag é decisão separada do operador com evidência.
Aceite por fatia: teste no binário exato (2.0.23) + security APPROVED + flags
inalteradas (OFF) até a decisão de ativação.

## F3 — MCP→subagent + S6 (W3)

- Experimento T0-T2 com 1 pergunta ("por que o turno parent não lista MCP
  tools no serve isolado?"), prompt de discovery obrigatório, medidas
  `GET /api/mcp` pré-turno + transcript do child + tool calls, stop em
  `provider.no-route`/TIMEOUT>240s/2x exit=1 rápido. Orçamento: 2-3 turnos
  curtos, 1 run por hipótese. Evidência sanitizada nova em
  `evidence/agent-mcp-integration/` (não tocar untracked existentes).
- Após a causa: corrigir S6 (lane `agent-mcp-integration-lane-v2.ps1`) e
  revalidar S5/S6 com modelo sob nova aprovação.

## F4 — RR-E2E-21 (W3, quota-gated)

- Retomada apenas com hipótese nova de prompt-shape (experimentos A-E do
  relatório de 2026-10-18); 1 run por hipótese; nunca repetir parâmetros;
  pernas kernel-side já provadas não são reexecutadas.
- Evidência nova em `evidence/v3.1/runtime-reliability/session-lane-*`.

## Validação e entrega

- Por fatia: testes focados + `git diff --check`; nas fatias de código,
  `scripts\test-package-consistency.ps1` + `scripts\v3\run-v3-tests.ps1`
  (+ `tests\distribution\run-distribution-tests.ps1` quando tocar distribuição).
- Cada fatia: coder → tester → reviewer (security quando autoridade/segurança);
  PR separado para master, CI verde, sem bypass.
- CHANGELOG: registrar em [Unreleased] a cada fatia entregue.
- Estado vivo: `evidence/v3.1/runtime-reliability/program-status.json`.

## Estado da execução (atualizado 2026-10-19)

- **F0 ENTREGUE** (branch `docs/reconcile-status-2026-10-19`): commit
  `d69e81c` publicado, **PR #130** aberto; 6 arquivos reconciliados;
  validação `tester` PASS (consistency 16/16 via pwsh, JSONs parseiam,
  diffs aditivos) + `reviewer` APPROVED após 1 rodada de correções.
- **Sync `release/0.2.0` → `master` (PR #129) com endurecimento do probe
  MCP antes do merge:** reviewer apontou 4 achados (sanitização com
  vazamento de credenciais, veredito sem provas estruturais, cleanup
  fail-open, gate de conexão) e o endurecimento passou por 5 rodadas de
  review; correções commitadas em `release/0.2.0` (`c93b758`, worktree
  `sync-129-probe-hardening`): sanitização fail-closed com desescape
  multi-pass, detector de residual e nuke integral do campo; provas
  estruturais por sessão no veredito (JSON válido ≠ transcript válido;
  status vazio ⇒ `unknown`; `parse_ok` exige envelope `data`); cleanup
  fail-closed e gate de conexão MCP obrigatório. Validação final: suíte
  110 PASS / 0 FAIL em PS 5.1 e pwsh (sem modelo/rede); `tester` PASS +
  `reviewer` APPROVED.
- **F1 S1 ENTREGUE** (branch `feat/f1-s1-native-bridge`, commit `744926f`,
  **PR #131**): bridge CLI `scripts/v3/native-dispatch-claim.ps1` (ação
  única `claim`; schema estrito com tipos crus; contexto só de arquivo com
  teto de 64 KiB em bytes e UTF-8 estrito; prompt ancorado no recibo
  durável via pré-read; saída sem authority:
  `grants_authority/verified_pass/done_approved=false`) + hook
  `execute.before` deny-only no plugin (modo isolado; tool-first; spawn
  `shell:false`; material canônico reconstruído e conferido antes do hash;
  fail-closed; nunca `allow:true`). Testes: 102 asserts PS (5.1+pwsh) + 41
  node (2 de integração com subprocesso real); regressão `objective-step`
  130/130. Verificação: `tester` PASS, `reviewer` APPROVED (4 rodadas),
  `security-reviewer` APPROVED (fixture-only; limitações declaradas no
  código: sem assinatura/integridade, path absoluto não confina, contexto
  exige ownership externo, bridge não emite admission file). F1 S2–S6
  pendentes.
- **F3/F4 bloqueadas por quota** (aprovação do operador com orçamento
  declarado); F3 também depende do merge do PR #129 (probe no master).
- **F2 não iniciada** (última por risco; exige prova `exact-binary-live` e
  decisão de operador para flags — seguem OFF).
- **F1 — decisão adotada (2026-10-19):** owner único da liquidação é
  `NativeDispatch.Settle` (canônico), com `ProductiveActivation` como proxy
  gated e `TaskKernel` como escritor autoritativo do worker-result; nenhum
  fallback para o escritor legado. Ambiguidade permanece fail-closed/manual
  nesta entrega (sem novo marcador causal kernel-side); S1 limitada a
  ambiente isolado até provar ausência/unload/ordenação de hooks. Flags e
  HOLDs inalterados. Memo do architect registrado na sessão de 2026-10-19.

## Decisões pendentes do operador

- Merge dos PRs #129 (sync), #130 (docs) e #131 (S1) após CI verde.
- Aprovação de quota por run (F3/F4) com orçamento declarado.
- Ativação de flags (F2) somente após evidência `exact-binary-live`.
- Promoção/release que dependam de resume live e MCPs com modelo.
