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

## Recuperação em segunda sessão (#177)

A lição foi gravada de forma durável em `lessons/m4-verified-learning.md`
(página `01a1c815-0ab1-70a0-9701-a8e04999e601`). Uma sessão nova
(`researcher`, `ses_e37ea6928ffeJRT2ctmj8XZFE3`) recuperou a página pelo MCP
ai-memory e respondeu:

- `LESSON_RECALLED: sim`
- Título: `Licao verificada: review aprovado + verify kernel-executed + DONE`
- Decisão: `candidate_pass` sem verificação kernel-executed e sem review
  aprovado **não** pode ser promovido a DONE/lição.
- Regra anti-gaming citada corretamente.

Isso fecha o ciclo `Kernel DONE → lição verificada → AI Memory → recuperação e
uso em outra sessão`.

## Segunda execução da receita (#77)

Receita de `m5-done-proof6-20261110` (`criterion-smoke`):

```
decision=REUSABLE deterministic=True profiles=criterion-smoke
run1=0 run2=0 model_calls=0
```

O procedimento foi executado duas vezes com o mesmo resultado e sem chamadas
de modelo, usando o perfil de verificação já existente. Nenhum executor novo
foi criado.

## Comparação de custo (#77)

Task `m4-recipe-proof2-20261110` (DONE, revision 13) executada com um coder
real e `model-attempt` registrado:

```
state=DONE model_attempts=1
recipe deterministic=True original_model_attempts=1
reuse=REUSABLE replay1=0 replay2=0 replay_model_calls=0
```

A execução original usou 1 chamada de modelo; o replay determinístico usou 0
em duas execuções, com o mesmo resultado. Nenhum executor novo foi criado.

## Limites

- #177: armazenamento, recall e uso em segunda sessão provados; resultados
  `UNKNOWN`/`PARTIAL`/não verificados são recusados.
- #77: extração, decisão de reuso e comparação de custo (1 chamada original →
  0 no replay) provadas.
- Nenhuma flag, permissão, credencial ou produção alterada.
