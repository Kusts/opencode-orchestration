# ADR — Swarm 2.4 (issue #124)

> **RESEARCH-ONLY — SEM import de servidor, SEM segundo orquestrador.**
> Este documento é pesquisa pura: verificação de claims upstream 2.2–2.4
> contra issues/docs primárias, matriz de compatibilidade e decisão
> registrada. Nenhum servidor Swarm entra em prod; nenhum override
> Planner/Kernel; nenhum bump OpenCode. Padrões ADOPT são isolados
> (gate shadow, inbox cursor+bulk para handoffs, shares read-only para #49).

- **Issue:** #124 — avaliar Swarm 2.4.
- **Decisão:** **HOLD import + ADOPT_PATTERN isolado (3 itens).**
- **Status:** research PARCIAL entregue (sem âncoras por issue — ver Fontes primárias); sem mudança de runtime, sem pin novo, sem flag nova.
- **Contexto RES-124:** upstream 2.2–2.4 validado (Jev gate #2182/#2226,
  receipts #2232, inbox cursor+bulk #2243, sessions+presence #2249,
  extraction #2290). Local já tem advisory-only + Kernel + flags
  `jev_advisory` ON.
- **Fontes primárias (PARCIAL — sem âncora por issue; números verificados
  em RES-124, trecho/parâmetro exato UNVERIFIED até citar âncora):**
  #2182 (Jev gate), #2226 (Jev gate), #2232 (receipts),
  #2243 (inbox cursor+bulk), #2249 (sessions+presence), #2290 (extraction).
  URLs base do repo upstream a vincular na revisão (ver §7).
- **Docs primárias vinculadas:** https://docs.agent-swarm.dev/docs/ui/configuration
  e https://docs.agent-swarm.dev/docs/concepts/workflows.

## 1. Claims upstream verificadas

| # | Claim | Verificação (fonte + parâmetro) | Versão / status |
|---|---|---|---|
| S1 | Jev gate: state ~1500 chars, `noul` p(needs action) | #2182 / #2226 — state ~1500 chars, questão `noul` p(needs action); trecho exato UNVERIFIED até âncora | 2.2–2.4 / PARCIAL |
| S2 | Thresholds replay: 229 ticks (Jev 0.5/100 skips, Clef 0.2/57 skips) | RES-124 replay 229 ticks: Jev 0.5/100 skips, Clef 0.2/57 skips; log exato UNVERIFIED até evidência anexada | 2.4 / PARCIAL |
| S3 | Custo ~$0.00004/decisão | RES-124; fatura/log exato UNVERIFIED | 2.4 / UNVERIFIED (ordem de grandeza) |
| S4 | Fail-open 60s (gate) — REQUISITO LOCAL, não comportamento upstream comprovado | Escolha local de invariante; semântica upstream exata (timeout path) UNVERIFIED até citar código/issue | 2.4 / PARCIAL (local) |
| S5 | Shadow vs enforce (gate em shadow por padrão) | RES-124 + local `jev_advisory` ON (advisory-only); default upstream UNVERIFIED até âncora | 2.4 / PARCIAL |
| S6 | Secrets globais (não por sessão) | RES-124; escopo exato UNVERIFIED até doc primária | 2.2–2.4 / UNVERIFIED |
| S7 | Mailbox: `/api/inbox-state` + `lastReadAt` + PATCH bulk 1–200 | #2243 — endpoint + cursor `lastReadAt` + bulk 1–200; contrato exato UNVERIFIED até schema | 2.4 / PARCIAL |
| S8 | AgentMail separado (canal distinto de handoffs) | #2243; boundary exato UNVERIFIED | 2.4 / PARCIAL |
| S9 | Presença realtime não persistida + RBAC | #2249 — sessions+presence; presença não persistida + RBAC; semântica exata UNVERIFIED | 2.4 / PARCIAL |
| S10 | Receipts (#2232) e extraction (#2290) existem no upstream | #2232 / #2290; sem adoção local neste ADR | 2.3–2.4 / REGISTRADO, sem adopt |
| S11 | Local: advisory-only + Kernel + flags `jev_advisory` ON | Estado local RES-124; nenhuma mudança neste ADR | local / OK |

## 2. Threat model

**Ativos:** credenciais do operador, handoffs/sessões locais, cursor
de leitura, permissões Planner/Kernel.

**Atores:** servidor Swarm remoto comprometido; tool/gate com falso
negativo; configuração errada (enforce prematuro, bulk abusivo);
operador em modo authoring.

**Vetores e controles:**

1. **Import de servidor = nova superfície de confiança** → HOLD (§4);
   nenhum fetch/exec remoto em prod.
2. **Enforce prematuro do gate (bloqueio/allow automático)** → REJECT
   (§5); só shadow advisory, sem override Planner/Kernel.
3. **Fail-closed acidental (timeout trava pipeline)** → exigir fail-open
   60s como invariante LOCAL (escolha local, não comportamento upstream
   comprovado) de qualquer experimento futuro; sem ele, HOLD.
4. **Secrets globais vazando por sessão** → segredos via env do runtime,
   nunca em handoff/log/telemetria; sem credencial nova neste ADR.
5. **Bulk PATCH abusivo (1–200) apagando/corrompendo fila** → bulk só
   para handoffs locais com cursor `lastReadAt`, limite explícito e
   rollback por log; sem bulk remoto.
6. **Presença realtime virando persistência/identidade** → presença é
   efêmera e não autoriza nada; RBAC local decide.
7. **Shares virando execução remota (#49)** → shares read-only, sem exec.

## 3. Matriz de compatibilidade

| Capacidade | Local (advisory-only + Kernel) | Upstream 2.4 | Veredito |
|---|---|---|---|
| Jev gate (state ~1500, `noul`) | advisory-only, `jev_advisory` ON | shadow vs enforce | **ADOPT-pattern shadow** (P1) |
| Inbox cursor + bulk | handoffs locais sem cursor/bulk | `/api/inbox-state` + `lastReadAt` + bulk 1–200 | **ADOPT-pattern local** (P2) |
| Shares / AgentMail | #49 pendente | AgentMail separado; shares | **ADOPT-pattern read-only** (P3) |
| Receipts #2232 | ausente | receipts | **HOLD** (sem adopt) |
| Sessions+presence #2249 | ausente | realtime não persistida + RBAC | **HOLD** (sem adopt) |
| Extraction #2290 | ausente | extraction | **HOLD** (sem adopt) |
| Import servidor Swarm | nenhum | servidor 2.4 | **HOLD** (sem import) |

## 4. Benefício mensurável / decisão — ADOPT_PATTERN (3 itens, isolados)

**P1 — Gate shadow (padrão Jev gate, sem enforce):**

- State compacto (~1500 chars) + questão `noul` p(needs action) como
  sinal advisory ao Planner; thresholds de referência replay 229 ticks
  (Jev 0.5/100 skips, Clef 0.2/57 skips); custo de referência
  ~$0.00004/decisão (UNVERIFIED, ordem de grandeza).
- **Gates P1:** shadow-only; sem override Planner/Kernel; fail-open 60s
  obrigatório como requisito LOCAL (não upstream comprovado); sem bump OpenCode; `jev_advisory` permanece ON.

**P2 — Inbox cursor + bulk para handoffs locais:**

- Adotar `lastReadAt` (cursor) + PATCH bulk limitado 1–200 **apenas**
  sobre fila local de handoffs; sem endpoint remoto.
- **Gates P2:** limite explícito por chamada; idempotência por cursor;
  log/rollback; sem AgentMail remoto.

**P3 — Shares read-only para #49:**

- Compartilhamentos somente leitura para o caso #49; presença efêmera,
  não persistida, sem poder de autorização; RBAC local.
- **Gates P3:** read-only enforced; sem exec remota; sem persistir presença.

**HOLD import — gates de saída (todos, sem exceção):**

1. Pin exato do servidor em registry + probe em runtime exato.
2. Contrato de API versionado sob review (inbox-state, bulk, RBAC).
3. Threat model de servidor remoto aprovado por security-reviewer.
4. Sem override Planner/Kernel; sem bump OpenCode sem decisão própria.
5. Fail-open 60s provado no binário pinado (requisito LOCAL; semântica
   upstream UNVERIFIED até âncora).

## 5. Rejeição explícita

- **REJECT** import do servidor Swarm 2.4 em prod (HOLD §4).
- **REJECT** enforce prematuro do gate (só shadow advisory; sem
  bloqueio/allow automático, sem override Planner/Kernel).
- **REJECT** bulk remoto ou sem cursor/idempotência.
- **REJECT** presença como autorização ou identidade persistida.
- **REJECT** shares com execução (só read-only para #49).
- **REJECT** Secrets por sessão/handoff/log; segredos só via env do runtime.

## 6. Sem dependência prod por padrão

- Nenhum servidor Swarm em prod; nenhum pin/flag/enforcement novo.
- Padrões P1–P3 são isolados e locais: gate shadow, cursor+bulk local,
  shares read-only.
- Sem wiring MCP novo; sem fetch remoto; sem credencial nova.
- Gaps que exigem probe/âncora antes de qualquer código: contrato exato
  `/api/inbox-state` + bulk, semântica fail-open 60s no binário pinado,
  escopo de Secrets globais, RBAC de sessions+presence, receipts #2232 e
  extraction #2290 (ambos HOLD, sem adopt aqui).

## 7. Referências

- Issues/PRs upstream citados em RES-124 (números verificados; URL base
  do repo a vincular na revisão — pesquisa PARCIAL até âncora por item):
  #2182, #2226 (Jev gate); #2232 (receipts);
  #2243 (inbox cursor+bulk, AgentMail); #2249 (sessions+presence);
  #2290 (extraction).
- Docs primárias agent-swarm vinculadas:
  https://docs.agent-swarm.dev/docs/ui/configuration e
  https://docs.agent-swarm.dev/docs/concepts/workflows.
- Estado local: advisory-only + Kernel + flags `jev_advisory` ON
  (RES-124; sem mudança neste ADR).
- Caso relacionado: #49 (shares read-only).
