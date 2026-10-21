# ADR — Skills over MCP (issue #56): ADAPTAR, sem Full, sem escalação

- **Issue:** #56 — avaliar Skills over MCP.
- **Decisão:** **ADAPTAR** (não full, não reject) — adotar somente padrão adaptado: loader local + identidade + protótipo shadow.
- **REJECT:** modo Full, ativação de `skill_routing` / `mcp_routing`, execução/autoload por servidor.
- **Status:** ADR registrado; protótipo **PLANEJADO — NÃO EXECUTADO**. Nenhuma skill remota carregada, nenhum pin ativado, nenhuma flag ligada por este ADR.
- **Escopo de escrita:** apenas este arquivo (`docs/plans/SKILLS-MCP-56-ADR.md`).

## 1. Contexto (RES-56)

- Upstream (changelog 10/10): `mcp.cloudflare.com` serve skills via `skills/list` + `skill://`.
- Spec SEP-2640: `server/discover`, `skills/list` / `skills/get`, `resources/read`, manifest atômico, `ttl` / `cacheScope` = freshness, verificação `size` + `sha256` + frontmatter, erros tipados.
- Client-matrix: sem modo Full; OpenCode ausente da matriz (sem suporte nativo comprovado).
- Local: `skill_routing` OFF, `mcp_routing` OFF; bridge somente identidade (`SELECTED_SKILLS` como ids, sem conteúdo, sem auto-load); loader local com kill-switch OFF; `shadow_table` + healthcheck como observação.
- Fases propostas: F0 HOLD; F1 protótipo shadow read-only opcional sem persistência; F2 opt-in 1–2 skills pinadas (`wrangler` + `workers-best-practices`).

## 2. O que ADAPTAR (adotar adaptado)

### 2.1 Loader local com kill-switch OFF (só identidade)

- Skills continuam locais e versionadas em repo; servidor MCP nunca injeta conteúdo executável.
- Bridge emite apenas identidade (`SELECTED_SKILLS` = ids validados contra registry com `status=available`); worker carrega pela via nativa e pode confirmar relevância, sem reorquestrar.
- Kill-switch default OFF; qualquer habilitação futura exige decisão humana com evidência + pin (server-id + URI + digest).

### 2.2 Manifest atômico + verificação

- Manifest atômico por skill: `server-id` + URI + `digest` (`sha256`) + `size` + frontmatter.
- Verificação obrigatória antes de qualquer uso futuro: `size` + `sha256` + frontmatter; divergência → `UNVERIFIED`, sem fallback silencioso.
- `ttl` / `cacheScope` interpretados como freshness, não como autoridade; expirado → refetch ou HOLD, nunca uso stale como verdade.

### 2.3 Protótipo shadow read-only (F1, NÃO EXECUTADO)

- Protótipo isolado, opcional, read-only, sem persistência: consulta `skills/list` / `skills/get` e `resources/read` contra 1–2 skills pinadas, registra em `shadow_table` + healthcheck.
- Nenhum auto-load, nenhum prefetch, nenhuma escrita, nenhum MCP novo habilitado.
- Saída do protótipo é evidência candidata, nunca prova; veredito final segue kernel/reviewer locais.

### 2.4 F2 condicional (opt-in, fora deste ADR)

- Somente após F1 verde: opt-in explícito para no máximo 1–2 skills pinadas (`wrangler`, `workers-best-practices`), cada uma com pin completo (server-id + URI + digest) + manifest anterior guardado para rollback.
- Ativação é decisão humana separada; este ADR não ativa F2.

## 3. Matriz de compatibilidade

| Capacidade upstream | Local atual | Veredito |
|---|---|---|
| `skills/list` + `skill://` (mcp.cloudflare.com) | sem suporte nativo (OpenCode ausente da client-matrix) | **ADAPT** via loader local + shadow (F1) |
| `server/discover`, `skills/list/get`, `resources/read` (SEP-2640) | bridge identity-only, sem fetch remoto | **ADAPT** somente como leitura shadow tipada |
| Manifest atômico + `ttl`/`cacheScope` | sem cache de skill remota | **ADAPT** freshness, sem autoridade |
| Verificação `size`+`sha256`+frontmatter + erros tipados | sem verifier de skill remota | **ADAPT** gate obrigatório p/ F2 |
| Modo Full (autoload/exec por servidor) | `skill_routing`/`mcp_routing` OFF | **REJECT** (§5) |
| Client-matrix Full | OpenCode ausente | **HOLD** até prova em runtime exato |

## 4. Threat model

**Ativos:** permissões Planner/Kernel, registry de skills, pins/digests, `shadow_table`/healthcheck, segredos do operador.

**Atores:** servidor MCP remoto comprometido; manifest adulterado; skill com nome colidido; configuração errada (autoload prematuro, cache stale como verdade).

**Vetores e controles:**

1. **Colisão de nome/namespace** → identidade por `server-id` + URI + digest, nunca só por nome; colisão → HOLD.
2. **Origem não confiável** → allowlist explícita de servidores; fora da allowlist → sem fetch.
3. **Conteúdo untrusted** → tratado como dado, nunca instrução; sem exec/autoload; verificação `size`+`sha256`+frontmatter antes de qualquer uso.
4. **Approval binding** → nenhum binding automático servidor→execução; qualquer uso futuro exige aprovação humana + pin.
5. **Verify ausente/burlado** → sem digest válido → `UNVERIFIED`, sem uso.
6. **Prefetch/dynamic indesejado** → sem prefetch; sem carregamento dinâmico; só leitura shadow explícita (F1).
7. **Cache stale** → `ttl`/`cacheScope` = freshness; expirado → refetch ou HOLD.
8. **Erros mascarados** → erros tipados surfaced (shadow_table), nunca silenciosos.

## 5. Rejeição explícita

- **REJECT** modo Full (autoload/exec por servidor, prefetch, dynamic).
- **REJECT** ativar `skill_routing` / `mcp_routing` por este ADR — ambas permanecem OFF; bridge segue identity-only.
- **REJECT** qualquer persistência ou wiring produtivo no protótipo (F1 é read-only, sem persistência).
- **REJECT** skill sem pin completo (server-id + URI + digest) ou sem verificação `size`+`sha256`+frontmatter.
- **REJECT** escalação de modelo/custo por este ADR — sem escalação; sem Astra; sem fan-out.

## 6. Versionamento / digest + rollback

- Pin por skill: `server-id` + URI + `digest` (`sha256`) registrados; bump só por decisão humana com evidência.
- Guardar manifest anterior a cada bump; rollback = republicar pin anterior + reverificação; divergência pós-rollback → HOLD.
- `shadow_table` + healthcheck observam sem decidir; sem telemetria com conteúdo de skill ou segredo (só ids/hashes/enums).

## 7. Sequência futura (NÃO EXECUTADA)

1. **F0 (HOLD):** nada executado; flags OFF confirmadas; `git diff --check` limpo.
2. **F1 (protótipo futuro, NÃO EXECUTADO):** shadow read-only opcional contra skills pinadas; registrar `shadow_table` + healthcheck; critério futuro: list/get/read tipados presentes, verificação OK, sem persistência, sem flag ligada.
3. **F2 (opt-in futuro, NÃO AUTORIZADO AQUI):** no máximo `wrangler` + `workers-best-practices` pinadas, com approval humano separado; qualquer ampliação → ADR novo.

## 8. Fora de escopo

- Nenhum modo Full; nenhum MCP novo habilitado; nenhum auto-load.
- Nenhuma ativação de flag (`skill_routing`, `mcp_routing`, `adaptive_ranking`, `runtime_grant_enforcement` seguem OFF).
- Nenhum commit/push executado por este trabalho.
- Arquivo tocado neste ADR: apenas `docs/plans/SKILLS-MCP-56-ADR.md`.
