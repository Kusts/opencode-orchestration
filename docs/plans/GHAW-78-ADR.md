# ADR — gh-aw (issue #78): ADAPT parcial, sem runtime Actions e sem enforcement

**Issue:** #78 — avaliar `gh-aw` (GitHub Agentic Workflows).
**Decisão:** **ADAPT parcial** — adotar somente: schema de eventos + par
`requested/actual` + grader com oráculo (golds) + safe-output boundary.
**REJECT:** runtime Actions, enforcement, ativação de flags.
**Status:** ADR registrado; fixture mínima **PLANEJADA — NÃO EXECUTADA
(não entregue)** — 1 objetivo V2 + 2 subagents, S/M; sem enforcement,
sem host-provenance.
**Escopo de escrita:** apenas este arquivo (`docs/plans/GHAW-78-ADR.md`).

## 1. Contexto (RES-78)

- Upstream `gh-aw`: v0.91.8 — timelines unificadas, normalização
  cross-engine, graders `code-read-precision`/`fitness`, mismatch surfaced,
  memory schema repair, hardening; v0.91.10/0.92.x — read-only default-deny,
  proveniência, MCP explícito, SHA de artefatos.
- Local: #4 (schema canônico de eventos), #30 (Goldens), #51 (PARTIAL),
  #69/#70 (bloqueiam ENFORCED), #49 (read-model).
- Protótipo (PLANEJADO, NÃO EXECUTADO): fixture mínima — 1 objetivo V2 +
  2 subagents, tamanho S/M, sem enforcement, sem host-provenance.
  Nenhuma execução entregue neste ADR.

## 2. O que ADAPT (adotar adaptado)

### 2.1 Eventos mínimos (sem event store paralelo a #4)

Reutilizar o schema canônico da #4; **nenhum event store paralelo**.
Campos mínimos adaptados do `gh-aw` (timelines unificadas + normalização
cross-engine, v0.91.8):

| Campo | Origem | Nota |
|---|---|---|
| `objective_id` | local (#4) | chave de correlação; não criar novo id-space |
| `requested` | gh-aw adaptado | o que foi pedido (prompt/constraints/escopo) |
| `actual` | gh-aw adaptado | o que foi produzido (artefato/refs) |
| `engine` | gh-aw normalizado | normalização cross-engine (nome + versão pinada) |
| `mismatch` | gh-aw surfaced | divergência `requested` vs `actual`, surfaced, não bloqueante |
| `provenance_ref` | local (#49 read-model) | leitura via read-model; sem host-provenance nova |

Regra: todo evento novo **estende** #4; se exigir store separado → HOLD.

### 2.2 Par `requested/actual`

- `requested`: intenção registrada antes da execução (objetivo V2 + critérios).
- `actual`: resultado observado depois (diffs, artefatos, refs).
- `mismatch` = comparação declarativa, apenas evidência (surfaced);
  nunca gate de enforcement (bloqueado por #69/#70).

### 2.3 Grader com oráculo (golds, #30)

Adaptar os graders `code-read-precision` / `fitness` (v0.91.8) sobre os
Goldens da #30:

- Oráculo = golds existentes (#30); nenhum gold novo neste ADR.
- Grader lê `requested`/`actual` e emite score + justificativa citando
  refs de critério (`criterion:<idx>:<evidência>`).
- Saída do grader é **candidata** (`candidate_pass`/`failed`), nunca
  `verified_pass`/`DONE` — veredito final segue o kernel local.
- Memory schema repair / hardening do upstream: observar como referência;
  reparo de schema local só via rito próprio, fora deste ADR.

### 2.4 Safe-output boundary

Adaptar o read-only default-deny + MCP explícito + SHA de artefatos
(v0.91.10/0.92.x) como boundary de saída do protótipo:

- Protótipo só escreve dentro de `WRITE_SCOPE` declarado (fixture mínima);
  resto read-only por padrão.
- MCP: somente explícito e allowlisted; nenhum MCP novo habilitado aqui.
- Artefatos do grader/fixture referenciados por SHA; sem SHA → UNVERIFIED.
- Nenhum segredo em eventos, golds ou logs.

## 3. Rejeição explícita

- **REJECT** runtime Actions (`gh-aw` como executor em CI/prod) — apenas
  leitura de schema/ideias; nenhum workflow agêntico ativo.
- **REJECT** enforcement a partir de `mismatch`/grader — #69/#70 bloqueiam
  ENFORCED; `mismatch` é evidência, não gate.
- **REJECT** event store paralelo a #4 — extensão ou nada.
- **REJECT** ativação de flags — nenhuma flag nova ou existente é ligada
  por este ADR; `capability_router`, `skill_routing`, `mcp_routing`,
  `adaptive_ranking`, `runtime_grant_enforcement` permanecem OFF.
- **REJECT** host-provenance nova — #49 read-model é o teto; sem coleta
  de proveniência de host neste protótipo.

## 4. Sequência futura (NÃO EXECUTADA) — baseline → fixture → veredito

> Escopo futuro: a sequência abaixo é plano, não entrega. Nenhum evento,
> score ou SHA foi produzido neste ADR.

1. **Baseline (futuro):** registrar estado pré-fixture (schema #4 vigente, golds #30
   vigentes, flags OFF); `git diff --check` limpo.
2. **Fixture (futura, NÃO EXECUTADA):** 1 objetivo V2 + 2 subagents (S/M), sem enforcement:
   emitir eventos §2.1, par `requested/actual`, rodar grader §2.3 sob
   safe-output boundary §2.4.
3. **Veredito (futuro, NÃO EXECUTADO):** publicar score do grader e `mismatch` surfaced como
   evidência candidata; decisão ADAPT/HOLD/REJECT registrada sem tocar
   flags, sem enforcement, sem store paralelo. Critério de aceite futuro:
   eventos mínimos presentes (conforme §2.1), score do grader citando golds (§2.3),
   boundary respeitado com SHAs referenciados (§2.4), `git diff --check` limpo.
   **Neste ADR/PR: nenhum outro arquivo tocado; artefatos futuros (eventos,
   score, SHAs) pertencem a PR separado, não a este.**

## 5. Fora de escopo

- Nenhum workflow `gh-aw` em CI; nenhum runner/mcp novo.
- Nenhum gold novo; nenhum repair de schema produtivo.
- Nenhum commit/push executado por este trabalho.
- Arquivo tocado neste ADR/PR: apenas `docs/plans/GHAW-78-ADR.md`. Artefatos futuros da fixture (eventos, score, SHAs) em PR separado.
