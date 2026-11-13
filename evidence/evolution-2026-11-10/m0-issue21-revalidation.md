# M0 — Revalidação da issue #21 (suítes de distribuição)

**Data:** 2026-11-10
**HEAD:** `54a9d3c` (merge PR #236) + alterações locais desta rodada (docs + check 17)
**Ambiente:** Windows, Windows PowerShell 5.1 (`powershell -NoProfile`)
**Objetivo:** revalidar as 6 suítes citadas na issue #21, que falhavam por
presumir dialeto V1 (`agent`) enquanto `install` com `runtime=Auto` resolvia V2
(`agents`), mais a ausência do pin exato no cenário (d) de `profile-isolation`.

## Comandos e resultados

| Suíte | Resultado | Asserts |
|---|---|---|
| `tests/distribution/config-format.tests.ps1` | PASS | 53 / 0 |
| `tests/distribution/config-preservation.tests.ps1` | PASS | 13 / 0 |
| `tests/distribution/fresh-install.tests.ps1` | PASS | 44 / 0 |
| `tests/distribution/planner-model.tests.ps1` | PASS | 9 / 0 |
| `tests/distribution/uninstall.tests.ps1` | PASS | 22 / 0 |
| `tests/distribution/profile-isolation.tests.ps1` | PASS | 39 / 0 (2 SKIP ambientais) |
| `tests/distribution/package-consistency.tests.ps1` | PASS | 3 / 0 (checker 17/17) |

## Observações

- As suítes executaram `install` com `runtime=V1 decision=target reason=explicit
  always wins (sem probe)`: a seleção explícita de runtime elimina o mecanismo
  original de falha (`Auto → V2` contra asserts que liam `agent` singular).
- `profile-isolation` cenário (d) ficou `SKIP` ambiental: o cache local tem
  OpenCode V2 2.0.18 e o pin vigente é 2.2.6, sem rede para provisionar o
  binário exato. O fail-closed por pin permanece correto; não é falha de
  isolamento.
- `fresh-install` passou 44/44 com dialeto V1 explícito e manifest
  `v1/gen 1/profile v1`, coerente com a suíte.

## Limites

- Não foi executada a matriz completa de 23 suítes de distribuição nesta
  passada; foram executadas as 6 suítes citadas na issue + o wrapper de
  consistência.
- A matriz V2-only isolada descrita no corpo da issue não foi repetida; a
  evidência aqui cobre a não-reprodução das 6 falhas originais no HEAD atual.
- Nenhuma issue foi fechada por esta rodada; o resultado é insumo para revisão
  do maintainer.

## Conclusão

As 6 falhas originais da #21 não se reproduzem no HEAD atual. A suíte está
estável com runtime explícito; a issue é candidata a `completed` após revisão
humana, com este arquivo como evidência.
