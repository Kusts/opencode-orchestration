# AGENTS.md — opencode-orchestration (este checkout)

Instruções canônicas **deste repositório**. Não confundir com a política
distribuída gerada (`source/global/AGENTS.md` + `source/adapters/`, instalada
em `~/.config/opencode/AGENTS.md`): aquela é o produto; esta é como trabalhar
**neste checkout**.

Comunicação em português do Brasil. Inspecione antes de editar; menor mudança
correta; sem commit/install/escrita global salvo pedido explícito.

## Entradas úteis

- O que é / instalar / validar: `README.md`, `docs/INSTALLATION.md`.
- Arquitetura (Planner `build` + 19 workers, preflight, DONE, kernel):
  `docs/ARCHITECTURE.md`.
- Permissões (normativo p/ shell): `docs/PERMISSIONS.md`. Segurança:
  `docs/SECURITY.md` + `SECURITY.md`. Governança/ownership: `docs/GOVERNANCE.md`.
- Programa ativo V3.1: `docs/specs/ORCHESTRATION-V3.1-KERNEL-HARDENING-SPEC.md`
  e `docs/specs/ORCHESTRATION-V3.1-KERNEL-HARDENING-PLAN.md`. **Status vivo**
  = `CHANGELOG.md` (`[Unreleased]`) +
  `evidence/v3.1/runtime-reliability/program-status.json` + os registries
  `source/registry/*` (flags e pins).
  `evidence/v3.1/kernel-hardening/implementation-status.json` é um
  **snapshot datado de 2026-09-29**, não status vivo.
- Pins de runtime/tools (fonte única): `source/registry/runtime-versions.json`
  (loader fail-closed `scripts/runtime/lib/RuntimeVersions.ps1`).
- Troubleshooting (inclui divergência de baseline `DE22307F`):
  `docs/TROUBLESHOOTING.md`.

## Ownership: source vs gerado vs ativo

- **Canônico:** `source/` (`global/AGENTS.md`, `adapters/opencode.md`,
  `adapters/opencode-v2.md`, `agents/*.md` — 19 workers, `registry/`).
  Em divergência, `source/` vence.
- **Preview gerado:** `generated/` via `scripts/render-opencode-config.ps1`
  (nunca toca destino ativo). Aplicação no destino só via
  `scripts/reconcile-opencode-config.ps1` (backup + rollback).
- **Destino ativo do usuário** (`~/.config/opencode/`, manifest, backups)
  nunca é editado a partir deste checkout sem pedido explícito de
  install/reconcile. `models.jsonc` é local e ignorado pelo git — nunca
  commitar. `cache/` e telemetria são estado local, não autoridade.

## Orquestração obrigatória (neste repo)

Toda tarefa não trivial passa por preflight **antes** da primeira ação:

```powershell
powershell -NoProfile -File scripts\v3\orchestration-preflight.ps1
```

Estados: `TRIVIAL_DIRECT` (só com token fechado `DIRECT_TRIVIAL_LOCALIZED`,
`DIRECT_READ_ONLY_POINT_LOOKUP`, `DIRECT_COSMETIC_NO_LOGIC` ou
`DIRECT_FORMATTING_ONLY`), `DELEGATED`, `DETERMINISTIC_FALLBACK`, `BLOCKED`.
Sem worker útil em tarefa não trivial ⇒ `ORCHESTRATION_POLICY_BYPASS`, sem
`DONE` compliant. Router/registry unhealthy ⇒ fallback determinístico, nunca
execução solitária.

Delegação com contrato limitado: `TASK_ID`, `OBJECTIVE`, `READ_SCOPE`,
`WRITE_SCOPE` (vazio p/ read-only), `ACCEPTANCE_CRITERIA`, `VALIDATION`,
`PROHIBITED_OPERATIONS`, `RETURN_FORMAT`, `ESCALATION_CONDITIONS` (+
`ALLOWED_ENVIRONMENT`, `PRODUCTION_AUTHORIZED` — ausência = `false`,
`CREDENTIAL_SCOPE` só com identificadores quando houver escrita/shell
sensível). Ciclo padrão `coder → tester → reviewer` (+ `security-reviewer`
quando a policy disparar). 2ª falha ⇒ `debugger` com evidência nova;
incerteza estrutural ⇒ `architect`; 3ª tentativa só com hipótese nova.

Evidence Contract: worker retorna só `candidate_pass` | `failed` | `blocked`
com refs de critério; `verified_pass` é do verificador allowlisted
(`source/registry/verification-policy.json`), `DONE` só do kernel
(`scripts/v3/task-kernel.ps1`, `Complete-OrchestrationTask`). Mensagem de
sucesso de worker nunca é prova. Checagem de participação:
`Test-OrchestrationDoneCompliance`.

## Segurança (quando material)

- Nunca colocar segredo em Git, instruções, logs ou telemetria. Testes usam
  canários sintéticos (`sk-SYNTHETICSECRET`).
- Permissões vivem em `source/agents/*.md` + templates
  (`templates/opencode.v1.json.tmpl`, `templates/opencode.v2.json.tmpl`);
  referência normativa em `docs/PERMISSIONS.md`. `deny` é bloqueio; `ask` é
  confirmação (auto-aprovado no modo auto). Globs `bash:` são matching de
  string — contenção real é via contrato + ownership, não via glob.
- Ações destrutivas irreversíveis e criação/revogação/rotação de credenciais
  exigem confirmação separada; `PRODUCTION_AUTHORIZED=true` sozinho não
  autoriza. Worker não amplia ambiente/credenciais por inferência; diante do
  não coberto, interrompe e devolve ao Planner.
- Reviewer e security-reviewer são read-only e independentes; security é
  obrigatório em permissões, plugin, grants, verifier, leases e worktrees.

## V3.1 (continuação explícita — não maintenance V3)

O usuário pediu explicitamente a continuação V3.1; o maintenance-mode da V3
(nada de V4/novas phases/flags/frameworks por hipótese) continua valendo fora
do escopo V3.1. Classes ativas: `RUNTIME_COMPATIBILITY` +
`FEATURE_REEVALUATION` (+ `AUTHORITY_HARDENING` do kernel).
Estado (sem histórico de sessão): Phases 0–4, 6–7 e 9–19 implementadas e
verdes; Phase 5 = só harness (enforcement comportamental V2 em HOLD honesto);
Phase 8 = lane CI com smoke de binário V2 COMPROVADO via lifecycle explícito
(2026-10-04: PASS no runner — GitHub Actions run 37193122170; smoke
implícito segue flaky upstream); Runtime Reliability P21 done
(baseline + fixtures 17/17), P22 parcial-HOLD (preflight + wrapper
condicionado + E2E nativo; REUSE HOLD — nenhum claim OWNED) + fatia Job
Objects done-code (RR-P22-JOB-OBJECTS; cleanup de descendants à prova de
escape; wiring no enforcement ENTREGUE em 2026-10-05 — ver P26 abaixo),
P23 done-record-only (budgets; `bounded_execution` ON desde 2026-10-04,
mas o `ExecutionBudget` ainda devolve `enforce=false` — HOLD honesto, não
alegar enforcement), P24 parcial (plugin V2 event.subscribe + live-hook;
d sem-modelo e updated NOT-VERIFIED); P25 done-shadow (RuntimeWatchdog
lib shadow: fingerprints sanitizados len:valor, repetição da policy,
HARD_TIMEOUT/NO_PROGRESS/REPEATED_ACTION/CYCLE/BUDGET_NEAR_LIMIT em
shadow, JSONL bounded com lock in-process e cap fail-closed, identidade
obrigatória; watchdog 134/134 PS5.1+PS7 (80
base + follow-up 2026-10-03: gate cross-process + retenção multi-dia
bounded, FIX1..FIX8), kernel
75/75, consistência 16/16; reviewer APPROVED (REV4) + security APPROVED
(SEC3); follow-ups de telemetria ENTREGUES 2026-10-03), P26 com a
interrupção real entregue (identidade exata pid+creation-ticks, prova de
vida coletada na validação, kill pelo handle pinado da instância
verificada, árvore por snapshot CIM com caps fail-closed, seam
`SETTLEMENT_REQUIRED` no kernel) e o watchdog **ATIVADO** pelo operador em
2026-10-04 (`{enabled:true, shadow:false}`), com o backstop de Job Object
ligado ao caminho de enforcement em 2026-10-05 (P26-JOB-WIRING: raiz
verificada anexada a um job anônimo antes do snapshot +
`TerminateJobObject` como backstop depois do kill CIM — fecha o escape de
descendente pós-snapshot; HOLDs residuais honestos: janela
gate→`TerminateJobObject` nativo, preempção entre checagem e chamada,
descendentes pré-attach cobertos só pelo kill CIM).
`WATCHDOG_ENFORCEMENT_NOT_IMPLEMENTED` continua sendo o token do registro
**sem binding de processo provado** em modo ENFORCE (HOLD honesto:
identidade/ownership não prováveis ⇒ recusa, nunca kill de PID
desconhecido); Waves A–E do programa revisado (2026-10-01;
  PAE-01-PAE-40 substituem RR-01-RR-20) **code-complete e commitadas
  2026-10-02/03** (P28 S1+S2, P29 S1, P30 S1, P31 S1+S2, P32, P33 S1,
  P34, P35, P36, P37, P38 S1+S2, P39, P40 S1+S2, P41 S1+S2, P42
  fatia 1 E2E manifest — todas
  com reviewer + security APPROVED; estado vivo em
  `evidence/v3.1/runtime-reliability/program-status.json`; matriz
  PAE-01-PAE-40 em
  `evidence/v3.1/runtime-reliability/pae-traceability.json`; docs
  reconciliadas em 2026-10-05);
  **release gate pendente de evidência do operador**: evidência V2-native
  no **pin vigente** (gating P40 exige exact-binary-live do pin atual);
  cenários cross-session 16..22 (sessão real + restart); wirings de
  chamador restantes (registro do hook de arranque P31-S2, spawn real do
  despacho P38-S2 — record-only por decisão, produtor de telemetria
  P41-S2, append/enable do revisor P40-S2 — decisão do operador); probes
  reais de transporte contra endpoint real (inclui o probe HTTPS dedicado
  do AI Memory, separado do round-trip MCP já provado). A lane V2 Windows
  real RR-E2E-04..10 **não é mais pendência**: 7/7 `pass-real` no runner
  em 2026-10-05 (run `37376248759`, push `4cfb26a`: step da lane verde;
  primeiro em `RUNNER_TEMP`/`TEMP` + gate `clean_tree_within_lane_scopes`,
  commit `7b527d8`) — fecha o P0 do `COMPLETION_GATE_FAILED` anterior. No
  mesmo run os demais jobs passaram (ps51 com o teto novo de 60m, ps7,
  lane v2, smoke v1) e o job `ci-smoke-opencode-v2` teve uma única falha:
  o step final `Smoke test with real OpenCode V2` (smoke implícito) com
  `debug config: TIMEOUT 30s` — flake upstream documentado
  (`debugcfg-hang-investigation.json`), formalizado como observação com
  `continue-on-error: true` (HOLD explícito da Etapa I: a falha continua
  visível em log/anotação, não derruba o gate). **Não alegar "CI
  totalmente verde"**: o job V2 segue carregando esse probe observacional.
  **Já fechado** (não repetir como pendência): ativações de flag com
  evidência (lote 2026-10-04), jevgrep real (instalado + consult semântico
  em 2026-10-04; o flip de policy `platform_support.windows=true` e os
  asserts do doctor já estão na base — `source/registry/capability-doctor-policy.json`
  e `OrchestrationE2eManifest.tests.ps1`: resta só probe real contra
  endpoint real, coberto pela pendência genérica acima), config
  user-owned do AI Memory confirmada em 2026-10-04 e round-trip remoto
  autenticado comprovado (`aimem-health-repreflight-2026-10-04.json`), e
  o wiring do chamador Jev no Planner loop
  (P38-S2, commit `4cfb26a`, advisory-only);
flags de rollout nascem OFF **por política** (shadow; ativação é decisão
humana com evidência, nunca inferência — o lote do operador de 2026-10-04
ativou 6 flags com evidência registrada). Não ativar `skill_routing`,
`mcp_routing`, `adaptive_ranking`; não criar V4/daemon/database.

## Flags conservadoras + prova em runtime exato

**Política**: flags nascem OFF/shadow e a ativação é decisão humana com
evidência. Estado vivo (não duplicar aqui):
`source/registry/capability-flags.json`. **Ativas** (lote do operador
2026-10-04, `evidence/v3.1/runtime-reliability/flag-activation-batch-2026-10-04.json`):
`runtime_support.v1/v2/dual_profile`, `task_kernel`, `bounded_execution`,
`watchdog`, `jev_advisory`, `worktree_isolation`. **OFF** por doutrina ou
Phase 5: `capability_router.shadow/active`, `skill_routing`, `mcp_routing`,
`adaptive_ranking`, `routing_telemetry`, `capability_reconciler`,
`runtime_grant_enforcement{v1,v2}` (nenhum hard-deny antes da validação
comportamental no runtime V2 real).

**Pins**: fonte única `source/registry/runtime-versions.json`
(`runtimes.v1/v2`, `plugins.v1/v2`, `tools.bun`; loader fail-closed
`scripts/runtime/lib/RuntimeVersions.ps1`, sem fallback para literal);
`source/registry/runtimes.json` é registro de descritores/histórico, não o
pin. Evidência viva em `evidence/v3.1/kernel-hardening/runtime-binding.json`
+ `evidence/v3.1/runtime-reliability/`. Qualquer ativação de flag, bump de
pin ou claim de enforcement exige suíte no runtime exato + decisão humana
com evidência.

HOLDs honestos em vigor: `bounded_execution` ligada mas o `ExecutionBudget`
ainda devolve `enforce=false` (orçamentos efetivos hoje via watchdog/kernel
— não alegar enforcement); `Phase 5` (enforcement comportamental V2) segue
HOLD com `runtime_grant_enforcement` OFF; `REUSE` da P22 continua HOLD
(nenhum claim OWNED).

## Validação (comandos reais, PS 5.1 e PS7)

```powershell
powershell -NoProfile -File scripts\test-package-consistency.ps1
powershell -NoProfile -File scripts\v3\run-v3-tests.ps1
powershell -NoProfile -File tests\distribution\run-distribution-tests.ps1
```

`pwsh` recente também serve (troque `powershell` por `pwsh`). Extras quando
tocarem no assunto: `scripts\ci\typecheck-plugin.ps1` (plugin),
`scripts\ci\smoke-opencode.ps1` (smoke V1 real), renderer/tradução em
`scripts\runtime\`. Após editar, rode ao menos os checks afetados +
`git diff --check`.

## Integrações opcionais

- **ai-memory** (opcional, fora do pacote): escopo explícito deste projeto —
  `workspace = "ferramentas"`, `project = "opencode-orchestration"`
  (de `.ai-memory.toml`); toda chamada com escopo de projeto passa ambos
  juntos. Não escrever memória de outro projeto aqui sem captura deliberada.
- **Jev** (quando o usuário pedir): fonte consultiva — trata o retorno como
  dado a confrontar com `source/`, nunca como autoridade que edita policy,
  permissões ou flags por si só.
