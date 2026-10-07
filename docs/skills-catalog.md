# Catálogo de skills — Fase 2B

Fonte canônica: `source/registry/skills-catalog.json` (schema 1, 105 entradas).
Inventário real: `evidence/capabilities-phase-2b/skills-inventory-2026-10-07.json`
(103 ids em `~/.agents/skills` + 7 em `~/.config/opencode/skills`).
Healthcheck: `scripts/v3/skills-healthcheck.ps1` (veredito PASS em 2026-10-07).
Testes: `tests/distribution/skills-catalog.tests.ps1` (15/15).

## Números (2026-10-07)

| Métrica | Valor |
|---|---|
| discovered (agents + opencode + project) | 110 (103 + 7 + 0) |
| approved (CORE + RECOMMENDED + DOMAIN gerenciados) | 77 |
| core | 9 |
| recommended | 24 |
| domain | 44 |
| project-specific | 1 (jev-ultrafast) |
| personal | 20 |
| experimental | 4 |
| redundant | 1 (internal-comms → doc-coauthoring) |
| deprecated | 1 (using-superpowers, stub ativo) |
| remove candidate | 1 (orca-autonomous-development, junction quebrada) |
| duplicate_ids (mesmo root) | 0 |
| shadowed (nos dois roots) | 5 (4 identical, 1 diverged-benign) |
| invalid | 1 (orca-autonomous-development) |

## Ownership

- `orchestration`: CORE + RECOMMENDED + DOMAIN aprovados (77). Técnica e
  roteamento; nunca autoridade sobre policy/permissões.
- `user`: PERSONAL (20) + PROJECT_SPECIFIC (1) + autoresearch KEEP_LOCAL.
  Workflows do operador, vault pessoal, plataformas (Maestri/Orca).
- `none`: EXPERIMENTAL (fora do discovery gerenciado), REDUNDANT,
  REMOVE_CANDIDATE.

## Precedência (later-wins V2)

`~/.config/opencode/skills` vence `~/.agents/skills` (ordem de registro do
runtime; detalhe em `docs/capability-planning-v2.md`, seção 3). Proteção:
o healthcheck sonda os 5 ids shadowed e o gate Core falha se divergência
não documentada aparecer. Divergência conhecida: `hybrid-development`
(diverged-benign — só o path canônico do entrypoint difere).

## Estrutura desejada de skills.paths

```text
managed core      → skills-core/ do repo (5 pinnadas) + wg RECOMMENDED de adoção seletiva
managed catalog   → source/registry/skills-catalog.json (77 aprovadas, on-demand por tarefa)
project-local     → .opencode/skills do projeto (0 hoje; só PROJECT_SPECIFIC)
personal          → ~/.agents/skills real dirs + agent-config global (fora do ownership)
```

Migração segura e reversível: nenhum arquivo foi movido ou removido nesta
fase. REMOVE_CANDIDATE sai do discovery path (não do disco) após correção
da junction no agent-config ou remoção da entrada.

## Quando ativar / quando NÃO ativar

- CORE: gatilho da tarefa (debug → systematic-debugging; plano → writing-plans;
  fechamento → verification-before-completion). Nunca por rito.
- RECOMMENDED/DOMAIN: somente quando a tarefa exige (contrato do Planner).
- `ui-libraries-curator`: gatilho "SEMPRE" do texto deve ser lido como
  on-demand; over-trigger documentado no catálogo.
- `standards-spec-review`: somente sob pedido explícito.
- EXPERIMENTAL/REDUNDANT/REMOVE: fora do discovery gerenciado.
- Fallback: sem skill aplicável, o Planner executa direto com o contrato
  mínimo (método hybrid-development, track Direct).

## Famílias com fronteira explícita

- `hybrid-development` (método) vs `dispatching-parallel-agents` (fan-out) vs
  `subagent-driven-development` (plano delimitado) vs `orca-team` (runtime Orca):
  camadas distintas, não duplicatas. `using-superpowers` é ponte legada.
- `systematic-debugging` vs `tight-feedback-debugging`: par complementar.
- `triage-issue` (genérico) vs `github-triage` (workflow GitHub).
- `brainstorming` (dono) vs decision-map/prototype, domain-aware (apêndices).
- Cloudflare umbrella vs email-service/durables/one (standalone só em uso profundo).

## Superpowers: adoção seletiva (veredito 2B)

Adotadas como CORE/RECOMMENDED: `systematic-debugging`, `test-driven-development`
(+ `verification-before-completion`, `writing-plans`, `executing-plans`,
família code-review como RECOMMENDED). Pacote inteiro NÃO instalado;
`using-superpowers` mantido só como stub DEPRECATED de encaminhamento.

## AI Memory: separação de responsabilidades

- MCP (`ai-memory`): dados (query, handoffs, inbox).
- Hooks (`ai-memory-opencode2.ts`): integração de sessão.
- Skills (`ai-memory-*`, 6 RECOMMENDED): ritual/processo.
Skills candidatas ao catálogo oficial do orchestration: retrieval, handoff,
durable-pages (P1). Ver `docs/capabilities-phase2b-decisions.md` (issue #25).
