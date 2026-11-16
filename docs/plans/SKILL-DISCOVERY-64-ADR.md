# ADR — Selective skill discovery (issue #64): ADAPT restrito, sem auto-install, sem escalação

> 8 skills-core atuais; 103 é histórico de 2026-10-07 e não descreve o inventário presente.

- **Issue:** #64 — avaliar selective skill discovery (search-first) sem preload total.
- **Decisão:** **ADAPT restrito** (não full, não reject) — adotar somente padrão adaptado: índice local + protótipo shadow offline + leitura exata verificada.
- **REJECT:** `skill_routing` / `mcp_routing`, Full/autoload, ativação em V1, auto-install, escalação de modelo.
- **Status:** ADR registrado; medição de custo executada (2026-11-12); protótipo F1 **NÃO** executado. Nenhum índice remoto consultado, nenhum pin ativado, nenhuma flag ligada por este ADR.
- **Escopo de escrita:** apenas este arquivo (`docs/plans/SKILL-DISCOVERY-64-ADR.md`).

## 1. Contexto (RES-64)

- Baseline local: preload estático + bridge identity-only (`SELECTED_SKILLS` como ids, máx. 3, kill-switch default OFF, sem conteúdo, sem auto-load).
- Upstream (OpenClaw 2026.10.1): search-first — `skills_search` (`query` 1–1000 chars, `limit` ≤ 5) retorna `name`/`location`/`description`/`coverage`/`provenance`; `skills_read` exato com verify (`256 KiB` por skill, `8 MiB` combinado); índice lexical, até 1024 skills, allowlists + gating.
- Sem grant por discovery em ambos os lados: descobrir não autoriza carregar, executar ou rotear.
- Métricas #30 + telemetria `skill-utility` como observação (suggested/accepted/loaded/used/helpful), sem re-ranking automático.
- Coordenação: #56 ADAPT (skills over MCP, loader local + shadow), #11 posterior (depende deste ADR, não liberado aqui), #62 freeze (V1 congelada — nada deste ADR entra em V1).
- Fases propostas: F0 HOLD; F1 protótipo shadow read-only offline; F2 opt-in exige ADR novo.

## 2. Baseline vs seletivo

| Dimensão | Baseline (preload estático) | Seletivo (search-first adaptado) | Veredito |
|---|---|---|---|
| Descoberta | tudo pré-carregado, custo fixo | busca por `query` + `limit ≤ 5`, só metadados | **ADAPT** só como leitura shadow (F1) |
| Leitura | via nativa local | `skills_read` exato + verify (`size`+digest+frontmatter; caps 256 KiB / 8 MiB) | **ADAPT** gate obrigatório p/ F2 |
| Índice | repo versionado | índice lexical local, ≤ 1024 entradas, com allowlist + gating | **ADAPT** offline, sem fetch remoto |
| Autorização | bridge identity-only (máx. 3, kill-switch OFF) | discovery não concede grant | **MANTER** — sem grant por discovery |
| Custo/modelo | sem escalação | risco de fan-out / escalação por busca | **REJECT** escalação (§5) |
| V1 | congelada (#62) | qualquer wiring em V1 | **REJECT** V1 (§5) |

## 3. O que ADAPTAR (adotar adaptado)

### 3.1 Índice local shadow (F1, NÃO EXECUTADO)

- Índice lexical local, offline, read-only, sem persistência produtiva: `query` (1–1000) + `limit` (≤ 5).
- Retorno só metadados: `name` / `location` / `description` / `coverage` / `provenance` — nunca conteúdo executável.
- Allowlist explícita de origens + gating; fora da allowlist → sem busca.
- Saída é evidência candidata, nunca prova; veredito final segue kernel/reviewer locais.

### 3.2 Leitura exata verificada (F1, NÃO EXECUTADA)

- `skills_read` somente exato (sem glob/prefix), com verify obrigatório: `size` + digest + frontmatter antes de qualquer uso futuro.
- Caps: `256 KiB` por skill, `8 MiB` combinado; excedeu → `UNVERIFIED`/HOLD, sem truncamento silencioso.
- Divergência → `UNVERIFIED`, sem fallback silencioso; expirado/stale → refetch ou HOLD, nunca uso como verdade.

### 3.3 Bridge e telemetria inalteradas

- Bridge segue identity-only (ids validados contra registry, máx. 3); worker carrega pela via nativa e pode confirmar relevância, sem reorquestrar.
- Kill-switch default OFF; qualquer habilitação futura exige decisão humana com evidência + pin.
- Telemetria `skill-utility` + métricas #30 só observam (suggested/accepted/loaded/used/helpful); sem auto-ranking, sem conteúdo de skill ou segredo (só ids/hashes/enums).

### 3.4 F2 condicional (opt-in, fora deste ADR)

- Somente após F1 verde e por ADR novo: opt-in explícito para conjunto mínimo pinado, cada entrada com pin completo (origem + localização + digest) + índice anterior guardado para rollback.
- Ativação é decisão humana separada; este ADR não ativa F2.

## 4. Threat model

**Ativos:** permissões Planner/Kernel, registry/índice de skills, pins/digests, telemetria `skill-utility`, segredos do operador.

**Atores:** índice remoto/descrição adulterada; skill com nome colidido; configuração errada (autoload prematuro, cache stale como verdade, `limit`/`query` abusivos).

**Vetores e controles:**

1. **Colisão de nome/namespace** → identidade por origem + localização + digest, nunca só por nome; colisão → HOLD.
2. **Descrição untrusted como instrução** → metadados tratados como dado, nunca instrução; sem exec/autoload por resultado de busca.
3. **Query/limit abusivos** → `query` 1–1000, `limit` ≤ 5; fora do envelope → rejeitar.
4. **Leitura parcial/fora do cap** → só leitura exata verificada; excedeu 256 KiB / 8 MiB → HOLD.
5. **Verify ausente/burlado** → sem digest válido → `UNVERIFIED`, sem uso.
6. **Grant por discovery** → descobrir nunca autoriza; qualquer uso futuro exige approval humano + pin.
7. **Cache stale** → freshness, não autoridade; expirado → refetch ou HOLD.
8. **Telemetria com conteúdo** → só ids/hashes/enums; sem conteúdo de skill ou segredo.

## 5. Rejeição explícita

- **REJECT** ativar `skill_routing` / `mcp_routing` por este ADR — ambas permanecem OFF; bridge segue identity-only.
- **REJECT** modo Full/autoload (preload total, prefetch, dynamic, auto-install por resultado de busca).
- **REJECT** qualquer wiring/ativação em V1 — freeze #62; nada deste ADR entra em V1.
- **REJECT** qualquer persistência ou wiring produtivo no protótipo (F1 é read-only offline, sem persistência).
- **REJECT** skill sem pin completo ou sem verificação (`size`+digest+frontmatter) e fora dos caps.
- **REJECT** escalação de modelo/custo por este ADR — sem escalação; sem Astra; sem fan-out; sem re-ranking automático.

## 6. Versionamento / digest + rollback + freeze V1

- Pin por entrada: origem + localização + digest registrados; bump só por decisão humana com evidência (em F2 futuro, via ADR novo).
- Guardar índice/manifest anterior a cada bump; rollback = republicar pin anterior + reverificação; divergência pós-rollback → HOLD.
- Freeze V1 (#62): este ADR não altera comportamento V1; F1/F2 miram somente linha futura, quando liberada.
- Coordenação: #56 fornece loader local + shadow (reuso, sem duplicar); #11 permanece posterior e não é liberado aqui.

## 7. Sequência futura (NÃO EXECUTADA)

1. **F0 (HOLD):** nada executado; flags OFF confirmadas; `git diff --check` limpo.
2. **F1 (protótipo futuro, NÃO EXECUTADO):** índice lexical offline + `skills_search` shadow (`query`/`limit` no envelope, só metadados) + `skills_read` exato verificado dentro dos caps; critério futuro: busca tipada presente, verificação OK, sem persistência, sem flag ligada, sem V1 tocada.
3. **F2 (opt-in futuro, NÃO AUTORIZADO AQUI):** conjunto mínimo pinado, com approval humano separado via ADR novo; qualquer ampliação → ADR novo.

## 8. Fora de escopo

- Nenhum modo Full; nenhum auto-install; nenhum prefetch/dynamic.
- Nenhuma ativação de flag (`skill_routing`, `mcp_routing`, `adaptive_ranking`, `runtime_grant_enforcement` seguem OFF).
- Nenhuma escalação de modelo; nenhum toque em V1 (#62 freeze).
- Nenhum commit/push executado por este trabalho.
- Arquivo tocado neste ADR: apenas `docs/plans/SKILL-DISCOVERY-64-ADR.md`.

## 9. Medição de custo (2026-11-12)

Medição **reproduzível** do custo de descoberta de skills, sem alteração de runtime/código de produto e **sem seleção seletiva executada**. Protótipo F1 (índice local shadow) **não executado**.

### Ferramenta e método

- Ferramenta: `scripts/v3/skill-discovery-metrics.ps1` + testes `17/17` em PS7 e PS5.1; `package-consistency 17/17`; `git diff --check` 0.
- Raízes medidas (default, refletindo o runtime): `skills-core` + `%USERPROFILE%\.config\opencode\skills`.
- Query de referência da seleção lexical: `review code changes findings`.
- `-SkipReparse` disponível como modo estrito para auditoria de origem (o default segue junctions porque o runtime as resolve).

### Números

| Métrica | Valor |
| --- | --- |
| Skills válidas / inválidas / ilegíveis | 133 / 1 / 0 |
| Junctions seguidos (default) | 109 |
| Metadados (estimativa `chars/4`) — por ocorrência | 10.174 tokens |
| Metadados (estimativa `chars/4`) — únicos (125 nomes) | 9.720 tokens |
| Razão corpo/metadados | **21,90** (corpo completo ≈ 21,9× os metadados) |
| Latência descoberta+parse (não determinística) | p50 ~196 ms · p95 ~296 ms (varia por máquina/carga) |
| Seleção lexical top-5 | `receiving-code-review`, `requesting-code-review`, `writing-skills`, `addy-incremental-delivery`, `code-craftsman` (~348 tokens estimados) |
| `selection_ratio_vs_unique` | **0,0358** (≈3,6% do baseline único de metadados) |
| Duplicatas entre raízes (8) | `addy-incremental-delivery`, `bmad-structured-delivery`, `dispatching-parallel-agents`, `hybrid-development`, `pocock-technical-decisions`, `subagent-driven-development`, `using-superpowers`, `verification-before-completion` |

### Achados

- **Drift de conteúdo:** `hybrid-development` apresenta conteúdo divergente (`differs=true`) entre `skills-core` e o catálogo global; as demais 7 duplicatas são idênticas entre raízes.
- **Determinismo:** o JSON sem o bloco `timing` é byte-a-byte idêntico entre execuções; `timing` varia (latência não determinística).

### Limitações

- Tokens são estimativa `chars/4`, **não** tokenização real.
- Frontmatter YAML-lite (campos `name`/`description` de linha única; blocos `>`/`|` marcados como *unsupported*).
- Junctions seguidas por padrão (alinhado ao runtime); modo `-SkipReparse` serve à auditoria de origem.
- Latência de descoberta+parse depende de máquina/carga (p50/p95 indicativos, não SLO).

### Ainda falta (para evoluir além de PARCIAL)

- Relevância/recall da seleção (a seleção lexical medida é indicativa, não validada por recall).
- Taxa de falsa seleção.
- Custo-até-DONE atribuído à descoberta/seleção (fim-a-fim).
- Continuidade de cache com Golden Workflows (sem medição de reuso/cold-vs-warm no fluxo real).
- **F1 (protótipo shadow, índice local + leitura exata verificada): não executado.** Promover a COBERTO exige evidência dessas dimensões.
