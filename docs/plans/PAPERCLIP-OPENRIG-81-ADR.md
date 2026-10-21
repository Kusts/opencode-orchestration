# ADR — Paperclip + OpenRig (issue #81): deny-closed + guidance/attach, sem serviço extra em prod

**Issue:** #81 — avaliar Paperclip (Assistant Connection MCP) + OpenRig (recovery/launcher) para needs_input/ATTN.
**Decisão:** **ADOTAR** deny-closed + guidance/launcher/attach; **ADAPTAR** ATTN + ladders + fail-loud local sem daemon; **REJEITAR** `enablePublicMcp` em prod, auto-spawn, setup auto-write, fallback global.
**Status:** ADR registrado; nenhuma flag, nenhum serviço, nenhum deploy por este documento.
**Escopo de escrita:** apenas este arquivo (`docs/plans/PAPERCLIP-OPENRIG-81-ADR.md`).
**Custo:** 1–2d (spike local + guidance + attach; sem daemon, sem prod).

## 1. Contexto (RES-81)

- Upstream **Paperclip `v2026.1012.0`** — Assistant Connection MCP: OAuth/device flow, 10 tools, eventos 2.0, webhooks, `enablePublicMcp` OFF por default, HTTPS. Breaking: **#14869** (locks) + **#14915** (deny-closed).
- Upstream **OpenRig `0.6.10`** — recovery: setup providers, resume com novo session ID, `rig up` em sessão existente, launcher, sends, `attention_required`, etc.
- Local: **#81 OPEN** (`needs_input` sem ATTN, estado `parked-owner-consumer`); **#49** fresh-primed; **#70** scope; **#9** cmux manual.
- Recomendação consolidada: ADOTAR deny-closed + guidance/launcher/attach; ADAPTAR ATTN + ladders + fail-loud local sem daemon; REJEITAR `enablePublicMcp` em prod, auto-spawn, setup auto-write, fallback global.

## 2. Baseline pinado

- **Pins:** Paperclip `v2026.1012.0` exato; OpenRig `0.6.10` exato. Não usar `main`/RC/nightly como prova; divergência doc × binário → vale o binário, registrar como gap.
- **Capacidades consideradas (a confirmar no binário pinado):**
  - Paperclip: OAuth/device, 10 tools MCP, eventos 2.0, webhooks, `enablePublicMcp` (default OFF), HTTPS obrigatório, locks (#14869), deny-closed (#14915).
  - OpenRig: setup providers, resume (novo session ID), `rig up` em existente, launcher, sends, `attention_required`.
- **Links upstream (verificação):**
  - Paperclip releases / Assistant Connection MCP: `https://github.com/paperclip` (release `v2026.1012.0`; issues `#14869` locks, `#14915` deny-closed).
  - OpenRig: `https://github.com/openrig` (release `0.6.10`; docs setup providers, resume, `rig up`, launcher, `attention_required`).

## 3. Matriz verificada (AC: matriz + links)

| # | Capacidade | Origem (pin) | Comportamento esperado | Uso local (#81) | Veredito |
|---|---|---|---|---|---|
| P1 | OAuth/device flow | Paperclip `v2026.1012.0` | device-code + token por usuário/sessão, sem segredo em log | Auth de operador local, via env; nunca auto em prod | **ADOTAR** (local/manual) |
| P2 | 10 tools MCP | Paperclip `v2026.1012.0` | tools explícitas, allowlist | Somente leitura/guidance; nenhuma tool nova habilitada por este ADR | **ADOTAR** (allowlist) |
| P3 | Eventos 2.0 + webhooks | Paperclip `v2026.1012.0` | evento versionado + entrega webhook | Observar como referência; sem webhook em prod neste ADR | **ADAPTAR** (schema ref.) |
| P4 | `enablePublicMcp` (default OFF) | Paperclip `v2026.1012.0` | OFF por default; ligar expõe MCP público | Manter OFF; ligar em prod = bloqueado | **REJEITAR em prod** |
| P5 | Locks (#14869, breaking) | Paperclip #14869 | lock explícito de sessão/recurso | Respeitar; sem bypass; conflito = fail-loud | **ADOTAR** |
| P6 | deny-closed (#14915, breaking) | Paperclip #14915 | fechado nega por padrão; abrir exige grant explícito | Base de authorization local | **ADOTAR** |
| O1 | setup providers | OpenRig `0.6.10` | configura provider/modelo | Manual/local; **sem auto-write** de config | **ADAPTAR** (manual) |
| O2 | resume (novo session ID) | OpenRig `0.6.10` | retoma com novo ID, sem reaproveitar ID morto | Attach explícito; novo ID ≠ continuação implícita | **ADOTAR** (attach) |
| O3 | `rig up` em existente | OpenRig `0.6.10` | sobe sobre sessão existente | Somente com ownership/lease provado; senão negar | **ADOTAR condicional** |
| O4 | launcher + sends | OpenRig `0.6.10` | lança/sinaliza sessões | Launcher como guidance local; **sem auto-spawn** | **ADAPTAR** (guidance) |
| O5 | `attention_required` | OpenRig `0.6.10` | sinaliza needs_input/ATTN | Adaptar para ATTN local + ladders + fail-loud, sem daemon | **ADAPTAR** |

Regras transversais: nenhum comportamento presumido além do binário pinado; `main`/posterior não é prova; gap bloqueante → HOLD da linha, sem promoção.

## 4. Fault / authorization (AC)

- **Modelo:** deny-closed (#14915) em tudo que este ADR toca: sem grant explícito (lease/ownership/escopo), negar. Locks (#14869) nunca burlados; contention = `blocked` + fail-loud, nunca retry silencioso nem fallback global.
- **Sinais:** `needs_input` sem ATTN (#81, `parked-owner-consumer`) → emitir `attention_required` adaptado local (sem daemon) + ladder de escalação; sem ATTN válido, estacionar e sinalizar, nunca auto-resolver.
- **Boundaries:** sem segredo em evento/log/webhook/telemetria; OAuth/device só via env do runtime; HTTPS onde houver transporte; `enablePublicMcp` ON em prod = violação (REJECT §6).
- **Fail-loud local:** qualquer negação/lock/ATTN sem dono gera evidência observável (criterion ref + motivo), sem daemon, sem serviço extra, sem spawn automático.

## 5. Comparação de gaps (AC)

| Gap | Paperclip | OpenRig | Local (#81/#49/#70/#9) | Tratamento |
|---|---|---|---|---|
| ATTN ausente (`needs_input` sem ATTN) | eventos 2.0 entregam, mas não criam dono | `attention_required` sinaliza, não resolve | #81 `parked-owner-consumer` | ADAPTAR: ATTN local + ladders + fail-loud, sem daemon |
| Resume/identidade | locks protegem sessão | resume gera **novo** session ID | #49 fresh-primed (fresco ≠ retomado) | ADOTAR attach explícito; nunca confundir novo ID com continuidade |
| Escopo/permissão | deny-closed por padrão | `rig up`/sends sem grant = risco | #70 scope | ADOTAR deny-closed; sem grant = negar |
| Orquestração manual | n/a (MCP) | launcher manual | #9 cmux manual | ADAPTAR launcher como guidance; sem auto-spawn |
| Exposição pública | `enablePublicMcp` OFF default | n/a | prod sem serviço extra | REJEITAR ON em prod |

## 6. Decisão: adotar / adaptar / rejeitar (AC)

**ADOTAR:** deny-closed (#14915) como base de authorization; locks (#14869) sem bypass; guidance + launcher documentado + attach explícito (resume = novo ID, `rig up` só com ownership).
**ADAPTAR:** `attention_required` → ATTN local + ladders + fail-loud sem daemon; eventos 2.0 como referência de schema (sem webhook prod); setup providers e launcher como fluxo manual/local.
**REJEITAR:** `enablePublicMcp` em prod (manter OFF); auto-spawn de sessões; setup com auto-write de config/credencial; fallback global (qualquer "se falhar, roda em outro lugar" implícito); ativação de flags (`capability_router`, `skill_routing`, `mcp_routing`, `adaptive_ranking`, `runtime_grant_enforcement` permanecem OFF); daemon/serviço extra em prod.

## 7. Custo, risco, fora de escopo (AC)

- **Custo: 1–2d.** Motivo: spike local nos binários pinados (matriz §3) + guidance/launcher/attach + ATTN adaptado; sem daemon, sem prod, sem integração profunda.
- **Riscos:** confundir resume (novo ID) com continuidade (mitiga: attach explícito); ligar `enablePublicMcp` por conveniência (mitiga: REJECT + default OFF); auto-spawn mascarando falta de dono (mitiga: fail-loud); presumir `main` como prova (mitiga: pins §2).
- **Fora de escopo:** implementação, deploy, webhook em prod, daemon/serviço, auto-spawn, auto-write de config, mudança de flags/policy/permissões, credencial nova, commit/push.
- Arquivo tocado: somente `docs/plans/PAPERCLIP-OPENRIG-81-ADR.md` (este documento).

## 8. Recomendação

**Registrar este ADR e executar o spike local §3 nos pins exatos antes de qualquer plano.** Spike verde → plano de guidance/attach + ATTN adaptado (1–2d), mantendo todos os REJECTs do §6. Qualquer FAIL em deny-closed, locks ou ATTN sem dono ⇒ HOLD, sem promoção.
