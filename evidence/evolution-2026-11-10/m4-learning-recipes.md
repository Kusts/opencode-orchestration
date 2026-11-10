# M4 — Aprendizado verificado e receitas determinísticas (#177/#77)

**Data:** 2026-11-10
**Base:** branch `feat/evolution-integrated-20261110`

## Entregue

`scripts/v3/lib/OrchestrationLearning.ps1` (funções puras):

- `Test-OrchestrationTaskLessonEligible` — gateway estrito: exige `state=DONE`,
  `verification.status=verified_pass`, `source/verification_source=kernel-executed`,
  `verifier_executed=true`, critérios e review `approved` quando presente.
  Qualquer desvio retorna reasons explícitas e bloqueia a lição.
- `New-OrchestrationLessonFromTask` — gera `lesson_id` SHA-256, Markdown com H1
  para o AI Memory existente, confiança `verified`, evidência e bloco
  anti-gaming. Não escreve memória por conta própria.
- `New-OrchestrationRecipeFromTask` — extrai perfis de verificação, escopos,
  critérios, ambiente, `base_revision` e contagem de chamadas de modelo;
  `deterministic=true` somente com verificação kernel-executed e perfis.
- `Test-OrchestrationRecipeReusable` — `REUSABLE`, `RECIPE_STALE_BASE`,
  `RECIPE_ENV_MISMATCH`, `RECIPE_NOT_DETERMINISTIC` ou `INVALID`.
- `Get-OrchestrationLessonQuery` — consulta de recuperação a partir do objetivo.

Testes: `OrchestrationLearning.tests.ps1` — **20/20 PASS** (elegibilidade,
lição, receita, reuso, base divergente, ambiente divergente, task não-DONE,
verificação caller/falha, review changes_required, sem critério, sem perfil).

## Prova com registro real

Sobre o registro real da Task `m5-done-proof6-20261110` (state `DONE`):

```
gate=True
lesson=True confidence=verified id=ccae5fedf7ca4f0593e353e4ed4024463cdb9053e5b9ea70ddd87c668233f76b
recipe=True deterministic=True profiles=criterion-smoke
reuse=REUSABLE
```

## Prova de round-trip no AI Memory MCP

O Markdown gerado foi escrito, lido e removido via MCP no escopo
`ferramentas/opencode-orchestration`:

- `memory_write_page` → página `01a1c77f-8d13-7182-b957-ed95e7e0beb4`;
- `memory_read_page` → título e corpo com o bloco anti-gaming;
- `memory_delete_page` → removida (sem resíduo).

Isso prova o caminho de armazenamento/recuperação. A aplicação da lição em uma
segunda sessão real (usar a lição para decidir) é o próximo passo de #177.

## Limites

- #177: armazenamento e recall provados; uso efetivo em outra sessão ainda não
  demonstrado. Resultados `UNKNOWN`/`PARTIAL`/não verificados são recusados.
- #77: extração e decisão de reuso implementadas; a segunda execução real do
  procedimento não foi rodada nesta fatia. Nenhum executor novo foi criado.
- Nenhuma flag, permissão, credencial ou produção alterada.
