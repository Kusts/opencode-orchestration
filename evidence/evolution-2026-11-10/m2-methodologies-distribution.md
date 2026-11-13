# M2 — Distribuição das quatro metodologias (#237 / #48)

**Data:** 2026-11-10
**HEAD:** `54a9d3c` + alterações locais desta rodada
**Runtime de validação:** PowerShell 5.1, instalação V1 explícita usada pelas
suítes de distribuição (o dialeto V1 é o modo que elas fixam; o conteúdo de
skills é independente do dialeto)

## Entregue

- `skills-core/bmad-structured-delivery/SKILL.md` — requisitos ambíguos,
  decomposição em fatias verticais, aceite observável, sequenciamento.
- `skills-core/pocock-technical-decisions/SKILL.md` — contrato de API/tipo/
  interface guiado por callers, estados inválidos, compatibilidade.
- `skills-core/addy-incremental-delivery/SKILL.md` — fatia vertical, revisão
  por correção, performance medida, fronteiras de arquitetura.
- `skills-core/hybrid-development/SKILL.md` — tabela de seleção por forma da
  tarefa, ligando as quatro origens (BMAD, Matt/Pocock, Addy, Superpowers via
  verificação) sem criar um segundo método.
- `install.ps1` passa a instalar 8 skills-core (antes 5); validação de fontes
  obrigatórias e lista de operações alinhadas.
- `source/registry/skills-catalog.json` ganhou as 3 entradas repo-pinned e o
  `repo-pinned` atualizado.
- Testes de distribuição atualizados (fresh-install, idempotency, rollback,
  skills-catalog, package-consistency).

## Conteúdo e licença

Os três SKILL.md são **texto original**, inspirados nas técnicas citadas
(BMAD Method v6.12 estável; Matt Pocock; Addy Osmani). Nenhum conteúdo upstream
foi copiado. Os arquivos declaram `license: MIT` e a atribuição no corpo.

## Validação

| Suíte | Resultado |
|---|---|
| `scripts/test-package-consistency.ps1` | 17/17 PASS (check 6 = 8 skills) |
| `tests/distribution/fresh-install.tests.ps1` | 53/0 PASS (8 skills instaladas, manifest íntegro) |
| `tests/distribution/idempotency.tests.ps1` | 17/0 PASS |
| `tests/distribution/rollback.tests.ps1` | 33/0 PASS |
| `tests/distribution/skills-catalog.tests.ps1` | 14/15 PASS; 1 falha ambiental (abaixo) |

### Falha ambiental registrada

`skills-healthcheck` retorna `FAIL` com `core-gate: hybrid-development`
(`diverged-undocumented`). Causa: os roots reais da máquina divergiram —
`~/.agents/skills/hybrid-development/SKILL.md` tem hash
`fa588f21…c406a15a4` e `~/.config/opencode/skills/hybrid-development/SKILL.md`
tem `7a166e9c…f29c42`. O `shadow_table` registra o par reconciliado em
2026-11-05. A divergência é de estado user-owned do operador; não foi causada
por esta rodada e não foi corrigida por escrita no home real (regra de
ownership). Correção operacional: reinstalar/reconciliar os roots do usuário.

## Aceite do marco

- Instalação isolada disponibiliza técnicas das quatro origens: **sim**.
- Microcorreção usa Direct: **sim** (`hybrid-development`, track Direct).
- Feature multifase seleciona técnica BMAD quando pertinente: **sim** (tabela
  de seleção + skill BMAD).
- Revisão complexa usa técnica Addy: **sim** (skill Addy).
- JEV continua opcional e consultivo: **sim** (nenhuma mudança).

## Limites / pendências

- **#48** entregue parcialmente: a seleção é explícita e carregada por gatilho,
  mas não há roteamento adaptativo por Objective/Goal no Kernel.
- **#64** não implementado: não houve medição de custo de contexto da
  descoberta seletiva nesta rodada.
- Nenhum conteúdo upstream foi vendorizado; se o operador quiser o texto
  canônico das origens, isso exige pin, licença e decisão de distribuição
  separadas.
